import Foundation

public struct DiffDisplayRow: Sendable, Identifiable, Equatable {
    public let id: Int
    public let oldIndex: Int?
    public let newIndex: Int?
    public let isChanged: Bool

    public init(id: Int, oldIndex: Int?, newIndex: Int?, isChanged: Bool) {
        self.id = id
        self.oldIndex = oldIndex
        self.newIndex = newIndex
        self.isChanged = isChanged
    }
}

public enum DiffDisplay {
    /// Aligns replacement lines and inserts blank cells where one side is shorter.
    /// The result preserves the order of both inputs exactly.
    public static func rows(for operations: [DiffOperation]) -> [DiffDisplayRow] {
        var rows: [DiffDisplayRow] = []
        rows.reserveCapacity(operations.count)
        var index = 0
        while index < operations.count {
            switch operations[index] {
            case .equal(let old, let new):
                rows.append(DiffDisplayRow(id: rows.count, oldIndex: old, newIndex: new, isChanged: false))
                index += 1
            case .delete, .insert:
                var deleted: [Int] = []
                var inserted: [Int] = []
                while index < operations.count {
                    switch operations[index] {
                    case .delete(let old): deleted.append(old)
                    case .insert(let new): inserted.append(new)
                    case .equal: break
                    }
                    if case .equal = operations[index] { break }
                    index += 1
                }
                for offset in 0..<max(deleted.count, inserted.count) {
                    rows.append(DiffDisplayRow(
                        id: rows.count,
                        oldIndex: offset < deleted.count ? deleted[offset] : nil,
                        newIndex: offset < inserted.count ? inserted[offset] : nil,
                        isChanged: true
                    ))
                }
            }
        }
        return rows
    }
}

public struct WordSegment: Sendable, Equatable {
    public let text: String
    public let changed: Bool
}

public struct WordDifference: Sendable {
    public let old: [WordSegment]
    public let new: [WordSegment]
}

public enum WordDiff {
    /// Token-level highlighting for a replaced line. Oversized lines are shown
    /// as wholly changed to bound work on minified or generated content.
    public static func compare(_ old: String, _ new: String, characterLimit: Int = 10_000) -> WordDifference {
        guard old.count + new.count <= characterLimit else {
            return WordDifference(
                old: [WordSegment(text: old, changed: true)],
                new: [WordSegment(text: new, changed: true)]
            )
        }
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        let difference = newTokens.difference(from: oldTokens)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return WordDifference(
            old: coalesce(oldTokens.enumerated().map { WordSegment(text: $0.element, changed: removed.contains($0.offset)) }),
            new: coalesce(newTokens.enumerated().map { WordSegment(text: $0.element, changed: inserted.contains($0.offset)) })
        )
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: Int?
        for character in text {
            let kind: Int
            if character.isWhitespace { kind = 0 }
            else if character.isLetter || character.isNumber || character == "_" { kind = 1 }
            else { kind = 2 }
            if let currentKind, currentKind != kind {
                tokens.append(current)
                current = ""
            }
            current.append(character)
            currentKind = kind
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func coalesce(_ segments: [WordSegment]) -> [WordSegment] {
        var result: [WordSegment] = []
        for segment in segments {
            if let last = result.last, last.changed == segment.changed {
                result[result.count - 1] = WordSegment(text: last.text + segment.text, changed: last.changed)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
