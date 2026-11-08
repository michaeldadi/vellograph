import Foundation

public struct DiffOptions: Sendable {
    public var ignoreWhitespace: Bool
    public var ignoreLineEndings: Bool

    public init(ignoreWhitespace: Bool = false, ignoreLineEndings: Bool = false) {
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreLineEndings = ignoreLineEndings
    }
}

public enum DiffOperation: Sendable, Equatable {
    case equal(old: Int, new: Int)
    case delete(old: Int)
    case insert(new: Int)
}

public struct DiffHunk: Sendable, Equatable, Identifiable {
    public let id: Int
    public let oldRange: Range<Int>
    public let newRange: Range<Int>

    public var deletionCount: Int { oldRange.count }
    public var insertionCount: Int { newRange.count }
}

public struct DiffResult: Sendable {
    public let operations: [DiffOperation]
    public let hunks: [DiffHunk]

    public var isEqual: Bool { hunks.isEmpty }
}

public enum DiffEngine {
    public static func compare(
        _ old: [TextLine],
        _ new: [TextLine],
        options: DiffOptions = .init()
    ) throws -> DiffResult {
        let oldKeys = old.map { key($0, options: options) }
        let newKeys = new.map { key($0, options: options) }
        let anchors = patienceAnchors(oldKeys, newKeys)
        var operations: [DiffOperation] = []
        var oldStart = 0
        var newStart = 0
        for (oldIndex, newIndex) in anchors + [(oldKeys.count, newKeys.count)] {
            try Task<Never, Never>.checkCancellation()
            operations += try segment(
                oldKeys, newKeys,
                oldRange: oldStart..<oldIndex,
                newRange: newStart..<newIndex
            )
            if oldIndex < oldKeys.count {
                operations.append(.equal(old: oldIndex, new: newIndex))
            }
            oldStart = oldIndex + 1
            newStart = newIndex + 1
        }
        return DiffResult(operations: operations, hunks: makeHunks(operations))
    }

    private static func key(_ line: TextLine, options: DiffOptions) -> String {
        var value = line.content
        if options.ignoreWhitespace {
            value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return value + (options.ignoreLineEndings ? "" : line.ending)
    }

    private static func patienceAnchors(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        var oldPositions: [String: [Int]] = [:]
        var newPositions: [String: [Int]] = [:]
        for (i, key) in old.enumerated() { oldPositions[key, default: []].append(i) }
        for (i, key) in new.enumerated() { newPositions[key, default: []].append(i) }
        let pairs = old.enumerated().compactMap { (i, key) -> (Int, Int)? in
            guard oldPositions[key]?.count == 1, let positions = newPositions[key], positions.count == 1 else { return nil }
            return (i, positions[0])
        }
        guard !pairs.isEmpty else { return [] }

        var tails: [Int] = []
        var previous = Array(repeating: -1, count: pairs.count)
        for i in pairs.indices {
            let value = pairs[i].1
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].1 < value { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var indices: [Int] = []
        var current = tails.last ?? -1
        while current >= 0 {
            indices.append(current)
            current = previous[current]
        }
        return indices.reversed().map { pairs[$0] }
    }

    private static func segment(
        _ old: [String], _ new: [String],
        oldRange: Range<Int>, newRange: Range<Int>
    ) throws -> [DiffOperation] {
        if oldRange.isEmpty { return newRange.map { .insert(new: $0) } }
        if newRange.isEmpty { return oldRange.map { .delete(old: $0) } }

        // The standard library's collection difference uses a Myers-style edit
        // script. Bound unusually large unmatched regions so an adversarial file
        // cannot monopolize memory or the UI.
        if oldRange.count + newRange.count > 30_000 {
            return oldRange.map { .delete(old: $0) } + newRange.map { .insert(new: $0) }
        }
        try Task<Never, Never>.checkCancellation()
        let difference = Array(new[newRange]).difference(from: Array(old[oldRange]))
        var deleted = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): deleted.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffOperation] = []
        var oldOffset = 0
        var newOffset = 0
        while oldOffset < oldRange.count || newOffset < newRange.count {
            if deleted.contains(oldOffset), oldOffset < oldRange.count {
                result.append(.delete(old: oldRange.lowerBound + oldOffset))
                oldOffset += 1
            } else if inserted.contains(newOffset), newOffset < newRange.count {
                result.append(.insert(new: newRange.lowerBound + newOffset))
                newOffset += 1
            } else if oldOffset < oldRange.count, newOffset < newRange.count {
                result.append(.equal(old: oldRange.lowerBound + oldOffset, new: newRange.lowerBound + newOffset))
                oldOffset += 1
                newOffset += 1
            } else if oldOffset < oldRange.count {
                result.append(.delete(old: oldRange.lowerBound + oldOffset))
                oldOffset += 1
            } else {
                result.append(.insert(new: newRange.lowerBound + newOffset))
                newOffset += 1
            }
        }
        return result
    }

    private static func makeHunks(_ operations: [DiffOperation]) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var oldPosition = 0
        var newPosition = 0
        var startOld: Int?
        var startNew: Int?
        func finish() {
            guard let startOld, let startNew else { return }
            hunks.append(DiffHunk(id: hunks.count, oldRange: startOld..<oldPosition, newRange: startNew..<newPosition))
        }
        for operation in operations {
            switch operation {
            case .equal:
                finish()
                startOld = nil
                startNew = nil
                oldPosition += 1
                newPosition += 1
            case .delete:
                if startOld == nil { startOld = oldPosition; startNew = newPosition }
                oldPosition += 1
            case .insert:
                if startOld == nil { startOld = oldPosition; startNew = newPosition }
                newPosition += 1
            }
        }
        finish()
        return hunks
    }
}

