import Foundation
import Testing
@testable import DiffCore

@Test func twoWayChoicesPreserveEqualRegionsAndRequireEveryDecision() throws {
    let left = try TextSnapshot(text: "first\nold\nlast\n")
    let right = try TextSnapshot(text: "first\nnew\nlast\n")
    let diff = try DiffEngine.compare(left.lines, right.lines)
    #expect(throws: TextResolutionError.unresolvedChange(0)) {
        try TextResolution.resolve(left: left.lines, right: right.lines, diff: diff, choices: [:])
    }
    #expect(try TextResolution.resolve(left: left.lines, right: right.lines, diff: diff,
                                       choices: [0: .left]).map(\.fullText).joined() == left.text)
    #expect(try TextResolution.resolve(left: left.lines, right: right.lines, diff: diff,
                                       choices: [0: .right]).map(\.fullText).joined() == right.text)
    #expect(try TextResolution.resolve(left: left.lines, right: right.lines, diff: diff,
                                       choices: [0: .both]).map(\.fullText).joined() ==
            "first\nold\nnew\nlast\n")
    #expect(try TextResolution.resolve(left: left.lines, right: right.lines, diff: diff,
                                       choices: [0: .neither]).map(\.fullText).joined() ==
            "first\nlast\n")
}

@Test func coordinatedReplacementRejectsChangedFileAndRetainsRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("text.txt")
    let original = Data("before\n".utf8)
    let changed = Data("changed\n".utf8)
    try original.write(to: target)
    #expect(throws: SafeTextWriteError.destinationChanged) {
        try changed.write(to: target)
        _ = try SafeTextWrite.replace(at: target, expected: original, with: Data("new\n".utf8))
    }
    #expect(try Data(contentsOf: target) == changed)
    let saved = try SafeTextWrite.replace(at: target, expected: changed,
                                          with: Data("new\n".utf8))
    #expect(try Data(contentsOf: target) == Data("new\n".utf8))
    #expect(try Data(contentsOf: saved.recoveryURL!) == changed)
}

@Test func newMergeOutputNeverOverwritesAnExistingFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("merged.txt")
    try SafeTextWrite.create(at: target, data: Data("resolved\n".utf8))
    #expect(try Data(contentsOf: target) == Data("resolved\n".utf8))
    #expect(throws: SafeTextWriteError.destinationChanged) {
        try SafeTextWrite.create(at: target, data: Data("replacement\n".utf8))
    }
    #expect(try Data(contentsOf: target) == Data("resolved\n".utf8))
}

@Test func coordinatedDeletionRejectsChangedFileAndKeepsRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("conflicted.bin")
    let original = Data([0, 1, 2, 255])
    let changed = Data([0, 3, 4, 255])
    try original.write(to: target)
    try changed.write(to: target)
    #expect(throws: SafeTextWriteError.destinationChanged) {
        _ = try SafeTextWrite.delete(at: target, expected: original)
    }
    #expect(try Data(contentsOf: target) == changed)
    let result = try SafeTextWrite.delete(at: target, expected: changed)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try Data(contentsOf: result.recoveryURL!) == changed)
    #expect(try SafeTextWrite.delete(at: target, expected: nil).recoveryURL == nil)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: result.recoveryURL!)
    #expect(throws: SafeTextWriteError.destinationChanged) {
        _ = try SafeTextWrite.delete(at: target, expected: nil)
    }
}
