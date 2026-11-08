import Foundation
import Testing
@testable import DiffCore

@Test func snapshotRoundTripPreservesCRLFAndBOM() throws {
    let original = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\nthree".utf8)
    let snapshot = try TextSnapshot(data: original)
    #expect(snapshot.lines.map(\.ending) == ["\r\n", "\n", ""])
    #expect(try snapshot.encode(snapshot.lines) == original)
}

@Test func diffReconstructsTargetWithRepeatedLines() throws {
    let old = try TextSnapshot(text: "a\nb\na\nc\n")
    let new = try TextSnapshot(text: "a\na\nB\nc\n")
    let result = try DiffEngine.compare(old.lines, new.lines)
    let reconstructed = result.operations.compactMap { operation -> TextLine? in
        switch operation {
        case .equal(_, let index), .insert(let index): new.lines[index]
        case .delete: nil
        }
    }
    #expect(reconstructed == new.lines)
    #expect(!result.hunks.isEmpty)
}

@Test func nonOverlappingThreeWayChangesMergeAutomatically() throws {
    let base = try TextSnapshot(text: "a\nb\nc\n")
    let ours = try TextSnapshot(text: "A\nb\nc\n")
    let theirs = try TextSnapshot(text: "a\nb\nC\n")
    let result = try MergeEngine.merge(base: base.lines, ours: ours.lines, theirs: theirs.lines)
    #expect(result.conflicts.isEmpty)
    #expect(try result.lines().map(\.fullText).joined() == "A\nb\nC\n")
}

@Test func overlappingThreeWayChangesRequireChoice() throws {
    let base = try TextSnapshot(text: "a\nb\n")
    let ours = try TextSnapshot(text: "a\nours\n")
    let theirs = try TextSnapshot(text: "a\ntheirs\n")
    let result = try MergeEngine.merge(base: base.lines, ours: ours.lines, theirs: theirs.lines)
    #expect(result.conflicts.count == 1)
    #expect(throws: MergeError.unresolvedConflict(0)) { try result.lines() }
    #expect(try result.lines(choices: [0: .ours]).map(\.fullText).joined() == "a\nours\n")
}

