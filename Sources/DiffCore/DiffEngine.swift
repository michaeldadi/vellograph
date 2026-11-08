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
        let oldKeys = try old.enumerated().map { index, line in
            if index.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            return key(line, options: options)
        }
        let newKeys = try new.enumerated().map { index, line in
            if index.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            return key(line, options: options)
        }
        let anchors = try patienceAnchors(oldKeys, newKeys)
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
        return DiffResult(operations: operations, hunks: try makeHunks(operations))
    }

    private static func key(_ line: TextLine, options: DiffOptions) -> String {
        var value = line.content
        if options.ignoreWhitespace {
            value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return value + (options.ignoreLineEndings ? "" : line.ending)
    }

    private static func patienceAnchors(_ old: [String], _ new: [String]) throws -> [(Int, Int)] {
        var oldPositions: [String: [Int]] = [:]
        var newPositions: [String: [Int]] = [:]
        for (i, key) in old.enumerated() {
            if i.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            oldPositions[key, default: []].append(i)
        }
        for (i, key) in new.enumerated() {
            if i.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            newPositions[key, default: []].append(i)
        }
        let pairs = try old.enumerated().compactMap { (i, key) throws -> (Int, Int)? in
            if i.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            guard oldPositions[key]?.count == 1, let positions = newPositions[key], positions.count == 1 else { return nil }
            return (i, positions[0])
        }
        guard !pairs.isEmpty else { return [] }

        var tails: [Int] = []
        var previous = Array(repeating: -1, count: pairs.count)
        for i in pairs.indices {
            if i.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
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
        var oldStart = oldRange.lowerBound
        var newStart = newRange.lowerBound
        var prefix: [DiffOperation] = []
        while oldStart < oldRange.upperBound, newStart < newRange.upperBound,
              old[oldStart] == new[newStart] {
            if prefix.count.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            prefix.append(.equal(old: oldStart, new: newStart))
            oldStart += 1
            newStart += 1
        }

        var oldEnd = oldRange.upperBound
        var newEnd = newRange.upperBound
        while oldEnd > oldStart, newEnd > newStart,
              old[oldEnd - 1] == new[newEnd - 1] {
            if (oldRange.upperBound - oldEnd).isMultiple(of: 4_096) {
                try Task<Never, Never>.checkCancellation()
            }
            oldEnd -= 1
            newEnd -= 1
        }

        let middle = try unmatchedSegment(old, new,
                                          oldRange: oldStart..<oldEnd,
                                          newRange: newStart..<newEnd)
        let suffix = try (oldEnd..<oldRange.upperBound).enumerated().map { offset, oldIndex in
            if offset.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            return DiffOperation.equal(old: oldIndex, new: newEnd + offset)
        }
        return prefix + middle + suffix
    }

    private static func unmatchedSegment(
        _ old: [String], _ new: [String],
        oldRange: Range<Int>, newRange: Range<Int>
    ) throws -> [DiffOperation] {
        if oldRange.isEmpty || newRange.isEmpty {
            return try coarseOperations(oldRange: oldRange, newRange: newRange)
        }

        // The standard library's collection difference uses a Myers-style edit
        // script. Bound both input size and the possible search area: two
        // unrelated 10,000-line blocks are much more expensive than a tiny
        // insertion beside a long unchanged prefix.
        if oldRange.count + newRange.count > 30_000 ||
            oldRange.count > 1_000_000 / newRange.count {
            return try coarseOperations(oldRange: oldRange, newRange: newRange)
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
            if result.count.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
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

    private static func coarseOperations(oldRange: Range<Int>, newRange: Range<Int>) throws -> [DiffOperation] {
        var result: [DiffOperation] = []
        result.reserveCapacity(oldRange.count + newRange.count)
        for index in oldRange {
            if result.count.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            result.append(.delete(old: index))
        }
        for index in newRange {
            if result.count.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
            result.append(.insert(new: index))
        }
        return result
    }

    private static func makeHunks(_ operations: [DiffOperation]) throws -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var oldPosition = 0
        var newPosition = 0
        var startOld: Int?
        var startNew: Int?
        func finish() {
            guard let startOld, let startNew else { return }
            hunks.append(DiffHunk(id: hunks.count, oldRange: startOld..<oldPosition, newRange: startNew..<newPosition))
        }
        for (index, operation) in operations.enumerated() {
            if index.isMultiple(of: 4_096) { try Task<Never, Never>.checkCancellation() }
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

