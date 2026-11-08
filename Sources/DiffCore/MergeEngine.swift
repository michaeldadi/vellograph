import Foundation

public enum MergeChoice: Sendable {
    case ours
    case theirs
    case both
    case neither
}

public enum MergeError: Error, Equatable {
    case unresolvedConflict(Int)
    case invalidChoice(Int)
}

public struct MergeConflict: Sendable, Identifiable {
    public let id: Int
    public let baseRange: Range<Int>
    public let base: [TextLine]
    public let ours: [TextLine]
    public let theirs: [TextLine]
}

public enum MergePiece: Sendable {
    case resolved([TextLine])
    case conflict(MergeConflict)
}

public struct MergeResult: Sendable {
    public let pieces: [MergePiece]

    public var conflicts: [MergeConflict] {
        pieces.compactMap { if case .conflict(let conflict) = $0 { conflict } else { nil } }
    }

    public func lines(choices: [Int: MergeChoice] = [:]) throws -> [TextLine] {
        var output: [TextLine] = []
        for piece in pieces {
            switch piece {
            case .resolved(let lines): output += lines
            case .conflict(let conflict):
                guard let choice = choices[conflict.id] else {
                    throw MergeError.unresolvedConflict(conflict.id)
                }
                switch choice {
                case .ours: output += conflict.ours
                case .theirs: output += conflict.theirs
                case .both: output += conflict.ours + conflict.theirs
                case .neither: break
                }
            }
        }
        return output
    }
}

public enum MergeEngine {
    private enum Side { case ours, theirs }
    private struct Edit {
        let range: Range<Int>
        let replacement: [TextLine]
        let side: Side
    }

    public static func merge(
        base: [TextLine], ours: [TextLine], theirs: [TextLine]
    ) throws -> MergeResult {
        let oursDiff = try DiffEngine.compare(base, ours)
        let theirsDiff = try DiffEngine.compare(base, theirs)
        let edits = (
            oursDiff.hunks.map { Edit(range: $0.oldRange, replacement: Array(ours[$0.newRange]), side: .ours) } +
            theirsDiff.hunks.map { Edit(range: $0.oldRange, replacement: Array(theirs[$0.newRange]), side: .theirs) }
        ).sorted { left, right in
            if left.range.lowerBound != right.range.lowerBound { return left.range.lowerBound < right.range.lowerBound }
            return left.range.upperBound < right.range.upperBound
        }
        var pieces: [MergePiece] = []
        var cursor = 0
        var index = 0
        var nextConflictID = 0
        while index < edits.count {
            try Task<Never, Never>.checkCancellation()
            let first = edits[index]
            var region = first.range
            var group = [first]
            index += 1
            while index < edits.count, overlaps(region, edits[index].range) {
                let next = edits[index]
                region = region.lowerBound..<max(region.upperBound, next.range.upperBound)
                group.append(next)
                index += 1
            }
            if cursor < region.lowerBound {
                pieces.append(.resolved(Array(base[cursor..<region.lowerBound])))
            }
            let oursEdits = group.filter { $0.side == .ours }
            let theirsEdits = group.filter { $0.side == .theirs }
            let oursLines = apply(oursEdits, to: base, in: region)
            let theirsLines = apply(theirsEdits, to: base, in: region)
            if oursEdits.isEmpty {
                pieces.append(.resolved(theirsLines))
            } else if theirsEdits.isEmpty || oursLines == theirsLines {
                pieces.append(.resolved(oursLines))
            } else {
                pieces.append(.conflict(MergeConflict(
                    id: nextConflictID,
                    baseRange: region,
                    base: Array(base[region]),
                    ours: oursLines,
                    theirs: theirsLines
                )))
                nextConflictID += 1
            }
            cursor = region.upperBound
        }
        if cursor < base.count { pieces.append(.resolved(Array(base[cursor...]))) }
        return MergeResult(pieces: pieces)
    }

    private static func overlaps(_ first: Range<Int>, _ second: Range<Int>) -> Bool {
        if first.isEmpty && second.isEmpty { return first.lowerBound == second.lowerBound }
        if first.isEmpty { return second.contains(first.lowerBound) }
        if second.isEmpty { return first.contains(second.lowerBound) }
        return first.lowerBound < second.upperBound && second.lowerBound < first.upperBound
    }

    private static func apply(_ edits: [Edit], to base: [TextLine], in region: Range<Int>) -> [TextLine] {
        var output: [TextLine] = []
        var cursor = region.lowerBound
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if cursor < edit.range.lowerBound { output += base[cursor..<edit.range.lowerBound] }
            output += edit.replacement
            cursor = max(cursor, edit.range.upperBound)
        }
        if cursor < region.upperBound { output += base[cursor..<region.upperBound] }
        return output
    }
}

