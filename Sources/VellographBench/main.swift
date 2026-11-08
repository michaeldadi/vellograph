import DiffCore
import Darwin
import DocumentCore
import FolderCore
import Foundation
import GitCore
import ImageCore

/// Deterministic core timing probe. This does not measure disk I/O or the first
/// visible SwiftUI viewport; those require separate app-level profiling.
private func textProbe(mebibytes: Int) throws {
    let lineCount = mebibytes * 16_384
    var lines = (0..<lineCount).map { index in
        "record-\(index) alpha beta gamma delta epsilon zeta eta theta\n"
    }
    let left = Data(lines.joined().utf8)
    lines[lineCount / 2] = "record-\(lineCount / 2) alpha beta CHANGED delta epsilon zeta eta theta\n"
    let right = Data(lines.joined().utf8)
    let clock = ContinuousClock()

    let parseStart = clock.now
    let before = try TextSnapshot(data: left)
    let after = try TextSnapshot(data: right)
    let parseTime = parseStart.duration(to: clock.now)

    let diffStart = clock.now
    let result = try DiffEngine.compare(before.lines, after.lines)
    let diffTime = diffStart.duration(to: clock.now)

    let rowsStart = clock.now
    let rows = DiffDisplay.rows(for: result.operations)
    let rowsTime = rowsStart.duration(to: clock.now)

    guard result.hunks.count == 1, rows.count == lineCount else {
        fatalError("The benchmark fixture did not produce the expected single change.")
    }
    print(String(format: "%d MiB target | actual %.2f MiB | %d lines | parse %.3f s | diff %.3f s | rows %.3f s",
                 mebibytes, Double(left.count) / 1_048_576, lineCount,
                 seconds(parseTime), seconds(diffTime), seconds(rowsTime)))
}

private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
}

private func peakResidentMiB() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return .nan }
    return Double(usage.ru_maxrss) / 1_048_576
}

private func folderProbe() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellograph-bench-\(UUID().uuidString)", isDirectory: true)
    let left = root.appendingPathComponent("left", isDirectory: true)
    let right = root.appendingPathComponent("right", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: left, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: right, withIntermediateDirectories: false)
    for directory in 0..<100 {
        let folder = left.appendingPathComponent(String(format: "d%03d", directory), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in 0..<999 {
            let item = folder.appendingPathComponent(String(format: "f%04d", file))
            guard fm.createFile(atPath: item.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
    let clock = ContinuousClock()
    let start = clock.now
    let differences = try FolderComparison.compare(left: left, right: right)
    let elapsed = start.duration(to: clock.now)
    guard differences.count == 100_000 else {
        fatalError("The 100,000-entry fixture did not produce 100,000 results.")
    }
    print(String(format: "100,000-entry folder comparison | %.3f s | %d results",
                 seconds(elapsed), differences.count))
}

private func folderCopyProbe() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellograph-copy-bench-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let sourceFile = source.appendingPathComponent("payload.bin")
    let destinationFile = destination.appendingPathComponent("payload.bin")
    guard fm.createFile(atPath: sourceFile.path, contents: nil),
          fm.createFile(atPath: destinationFile.path, contents: Data("old".utf8)) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: sourceFile)
    let block = Data(repeating: 0x5A, count: 1_048_576)
    for _ in 0..<64 { try writer.write(contentsOf: block) }
    try writer.close()
    let fixturePeak = peakResidentMiB()

    let clock = ContinuousClock()
    let planStart = clock.now
    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["payload.bin"])
    let planTime = planStart.duration(to: clock.now)
    let planPeak = peakResidentMiB()
    let applyStart = clock.now
    let result = try plan.apply()
    let applyTime = applyStart.duration(to: clock.now)
    let applyPeak = peakResidentMiB()
    guard result.appliedCount == 1,
          try Data(contentsOf: result.recoveryFolder!
            .appendingPathComponent("payload.bin")) == Data("old".utf8),
          try FolderComparison.compare(left: source, right: destination)
            .allSatisfy({ $0.state == .equal }) else {
        fatalError("The folder copy did not preserve exact source and recovery content.")
    }
    print(String(format: "64 MiB reviewed folder replacement | plan %.3f s | apply %.3f s | peak MiB fixture %.0f / plan %.0f / apply %.0f / verified %.0f",
                 seconds(planTime), seconds(applyTime), fixturePeak, planPeak,
                 applyPeak, peakResidentMiB()))
}

private func byteComparisonProbe() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellograph-bytes-bench-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let left = root.appendingPathComponent("left.bin")
    let right = root.appendingPathComponent("right.bin")
    for url in [left, right] {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let writer = try FileHandle(forWritingTo: url)
        let block = Data(repeating: 0x7B, count: 1_048_576)
        for _ in 0..<64 { try writer.write(contentsOf: block) }
        try writer.close()
    }
    let clock = ContinuousClock()
    let start = clock.now
    guard try ByteComparison.areIdentical(left, right) else {
        fatalError("The byte comparison misclassified identical files.")
    }
    let elapsed = start.duration(to: clock.now)
    print(String(format: "64 MiB exact byte comparison | %.3f s | peak %.0f MiB",
                 seconds(elapsed), peakResidentMiB()))
}

private func imageProbe(left: URL, right: URL) throws {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try PixelDifference.compare(left: left, right: right)
    let elapsed = start.duration(to: clock.now)
    guard result.totalPixelCount > 0, result.changedPixelCount > 0 else {
        fatalError("The image fixture did not produce changed pixels.")
    }
    print(String(format: "%d × %d image difference | %.3f s | %d changed pixels",
                 result.width, result.height, seconds(elapsed), result.changedPixelCount))
}

private func gitProbe() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellograph-git-bench-\(UUID().uuidString)", isDirectory: true)
    let files = root.appendingPathComponent("tracked", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // Keep the fixture independent of the developer's Git identity and hooks.
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let message = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "VellographBench.Git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            String(decoding: message.prefix(1_000), as: UTF8.self)])
        }
    }

    try git(["init", "-q"])
    try git(["config", "user.name", "Vellograph Benchmark"])
    try git(["config", "user.email", "benchmark@localhost"])
    for directory in 0..<50 {
        let folder = files.appendingPathComponent(String(format: "d%02d", directory), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in 0..<100 {
            let path = folder.appendingPathComponent(String(format: "f%03d.txt", file))
            guard fm.createFile(atPath: path.path, contents: Data("original\n".utf8)) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
    try git(["add", "--", "tracked"])
    try git(["commit", "-q", "-m", "Benchmark baseline"])

    for index in 0..<1_000 {
        let folder = index / 100
        let file = index % 100
        let relative = String(format: "tracked/d%02d/f%03d.txt", folder, file)
        try Data("changed \(index)\n".utf8).write(to: root.appendingPathComponent(relative))
    }
    try git(["add", "--", "tracked/d00", "tracked/d01", "tracked/d02"])
    // d02 has 100 staged files; the benchmark includes partially staged
    // changes by editing a subset again after staging.
    for index in 0..<50 {
        let path = root.appendingPathComponent(String(format: "tracked/d02/f%03d.txt", index))
        try Data("staged and changed again \(index)\n".utf8).write(to: path)
    }
    for index in 0..<25 {
        let path = root.appendingPathComponent(String(format: "tracked/d20/f%03d.txt", index))
        try fm.removeItem(at: path)
    }
    for index in 0..<100 {
        let path = root.appendingPathComponent(String(format: "untracked-%03d.txt", index))
        guard fm.createFile(atPath: path.path, contents: Data("untracked\n".utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    let client = GitClient()
    let clock = ContinuousClock()
    let openStart = clock.now
    let repository = try client.repository(at: root)
    let openTime = openStart.duration(to: clock.now)
    guard repository.status.count == 1_125 else {
        fatalError("Expected 1,125 busy worktree entries, got \(repository.status.count).")
    }
    var statusTimes: [Double] = []
    for _ in 0..<3 {
        let start = clock.now
        let entries = try client.status(in: root)
        statusTimes.append(seconds(start.duration(to: clock.now)))
        guard entries.count == repository.status.count else {
            fatalError("Git status changed during the benchmark.")
        }
    }
    print(String(format: "5,000 tracked files | 1,125 changed paths | repository open %.3f s | status %.3f / %.3f / %.3f s",
                 seconds(openTime), statusTimes[0], statusTimes[1], statusTimes[2]))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 3, arguments[0] == "--image" {
        try imageProbe(left: URL(fileURLWithPath: arguments[1]),
                       right: URL(fileURLWithPath: arguments[2]))
    } else if arguments == ["--folder100k"] {
        try folderProbe()
    } else if arguments == ["--folder-copy"] {
        try folderCopyProbe()
    } else if arguments == ["--byte-compare"] {
        try byteComparisonProbe()
    } else if arguments == ["--git-busy"] {
        try gitProbe()
    } else if !arguments.isEmpty {
        fputs("Usage: vellograph-bench [--folder100k | --folder-copy | --byte-compare | --git-busy | --image LEFT RIGHT]\n", stderr)
        exit(2)
    } else {
        for size in [1, 10] { try textProbe(mebibytes: size) }
    }
} catch {
    fputs("Benchmark failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
