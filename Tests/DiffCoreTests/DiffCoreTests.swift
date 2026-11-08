import Foundation
import Testing
@testable import DiffCore

@Test func snapshotRoundTripPreservesCRLFAndBOM() throws {
    let original = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\nthree".utf8)
    let snapshot = try TextSnapshot(data: original)
    #expect(snapshot.lines.map(\.ending) == ["\r\n", "\n", ""])
    #expect(try snapshot.encode(snapshot.lines) == original)
}

@Test func snapshotRoundTripPreservesUnicodeAndBothUTF16ByteOrders() throws {
    let text = "café\r\n👩🏽‍💻\n最後\rfin"
    for encoding in [TextEncoding.utf16LittleEndian, .utf16BigEndian] {
        let created = try TextSnapshot(text: text, encoding: encoding, hasByteOrderMark: true)
        let parsed = try TextSnapshot(data: created.originalData)
        #expect(parsed.encoding == encoding)
        #expect(parsed.hasByteOrderMark)
        #expect(parsed.text == text)
        #expect(try parsed.encode(parsed.lines) == created.originalData)
    }
}

@Test func snapshotHandlesEmptyAndRejectsMalformedInput() throws {
    let empty = try TextSnapshot(data: Data())
    #expect(empty.lines.isEmpty)
    #expect(try empty.encode(empty.lines).isEmpty)
    #expect(throws: SnapshotError.binaryContent) {
        try TextSnapshot(data: Data([0x00, 0x01]))
    }
    #expect(throws: SnapshotError.unsupportedEncoding) {
        try TextSnapshot(data: Data([0xC3, 0x28]))
    }
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

@Test func largeRepeatedTextKeepsUnchangedRegions() throws {
    let common = TextLine(content: "same", ending: "\n")
    let before = Array(repeating: common, count: 31_000)
    let identical = try DiffEngine.compare(before, before)
    #expect(identical.hunks.isEmpty)
    #expect(identical.operations.count == before.count)

    var after = before
    after[15_500] = TextLine(content: "changed", ending: "\n")
    let changed = try DiffEngine.compare(before, after)
    #expect(changed.hunks.count == 1)
    #expect(changed.hunks[0].oldRange == 15_500..<15_501)
    #expect(changed.hunks[0].newRange == 15_500..<15_501)
}

@Test func unrelatedLargeBlocksUseOneCoarseChange() throws {
    let before = (0..<2_000).map { TextLine(content: "before-\($0)", ending: "\n") }
    let after = (0..<2_000).map { TextLine(content: "after-\($0)", ending: "\n") }
    let result = try DiffEngine.compare(before, after)
    #expect(result.operations.count == 4_000)
    #expect(result.hunks.count == 1)
    #expect(result.hunks[0].oldRange == 0..<2_000)
    #expect(result.hunks[0].newRange == 0..<2_000)
    #expect(result.operations.compactMap { operation -> Int? in
        if case .insert(let index) = operation { return index }
        return nil
    } == Array(after.indices))
}

@Test func diffOperationsRemainOrderedAndEqualLinesMatch() throws {
    var seed: UInt64 = 0x6d616364696666
    func next(_ count: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(count))
    }
    let alphabet = ["a\n", "b\n", "c\r\n", "x", "\n"]
    for _ in 0..<500 {
        let old = try TextSnapshot(text: (0..<next(35)).map { _ in alphabet[next(alphabet.count)] }.joined())
        let new = try TextSnapshot(text: (0..<next(35)).map { _ in alphabet[next(alphabet.count)] }.joined())
        let result = try DiffEngine.compare(old.lines, new.lines)
        var oldIndices: [Int] = []
        var newIndices: [Int] = []
        for operation in result.operations {
            switch operation {
            case .equal(let left, let right):
                #expect(old.lines[left] == new.lines[right])
                oldIndices.append(left)
                newIndices.append(right)
            case .delete(let left): oldIndices.append(left)
            case .insert(let right): newIndices.append(right)
            }
        }
        #expect(oldIndices == Array(old.lines.indices))
        #expect(newIndices == Array(new.lines.indices))
    }
}

@Test func cancelledDiffDoesNotProduceAResult() async throws {
    let lines = Array(repeating: TextLine(content: "same", ending: "\n"), count: 100_000)
    let worker = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try DiffEngine.compare(lines, lines)
    }
    do {
        _ = try await worker.value
        Issue.record("A cancelled comparison returned a result")
    } catch is CancellationError {
        // Expected: cancellation is observed before building the full diff.
    }
}

@Test func alignedRowsPreserveBothInputOrders() throws {
    let old = try TextSnapshot(text: "a\nold 1\nold 2\nz\n")
    let new = try TextSnapshot(text: "a\nnew\nz\n")
    let diff = try DiffEngine.compare(old.lines, new.lines)
    let rows = DiffDisplay.rows(for: diff.operations)
    #expect(rows.compactMap(\.oldIndex) == Array(old.lines.indices))
    #expect(rows.compactMap(\.newIndex) == Array(new.lines.indices))
    #expect(rows.contains { $0.oldIndex != nil && $0.newIndex == nil })
}

@Test func wordDifferencePreservesTextAndMarksOnlyReplacement() {
    let difference = WordDiff.compare("total = 10", "total = 20")
    #expect(difference.old.map(\.text).joined() == "total = 10")
    #expect(difference.new.map(\.text).joined() == "total = 20")
    #expect(difference.old.filter(\.changed).map(\.text).joined() == "10")
    #expect(difference.new.filter(\.changed).map(\.text).joined() == "20")
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

