import DiffCore
import FolderCore
import Foundation
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

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 3, arguments[0] == "--image" {
        try imageProbe(left: URL(fileURLWithPath: arguments[1]),
                       right: URL(fileURLWithPath: arguments[2]))
    } else if arguments == ["--folder100k"] {
        try folderProbe()
    } else if !arguments.isEmpty {
        fputs("Usage: vellograph-bench [--folder100k | --image LEFT RIGHT]\n", stderr)
        exit(2)
    } else {
        for size in [1, 10] { try textProbe(mebibytes: size) }
    }
} catch {
    fputs("Benchmark failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
