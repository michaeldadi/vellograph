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

