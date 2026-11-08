/// Small, bounded lexical scanner for the comparison view. Ranges use UTF-16
/// offsets so AppKit can apply them directly to attributed strings. This is a
/// display aid, not a parser or a source-code transformation.
public enum SyntaxDialect: Sendable {
    case plain, swift, javascript, json, python, xml, yaml, markdown, shell
}

public enum SyntaxScopeKind: Sendable, Equatable {
    case string, comment
}

public struct SyntaxScope: Sendable, Equatable {
    public let start: Int
    public let length: Int
    public let kind: SyntaxScopeKind

    public init(start: Int, length: Int, kind: SyntaxScopeKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }
}

public enum SyntaxScanner {
    private enum State {
        case normal
        case blockComment(Int)
        case xmlComment
        case multilineString([UInt16])
    }

    public static func scan(_ lines: [String], dialect: SyntaxDialect) -> [[SyntaxScope]] {
        guard dialect != .plain, dialect != .markdown else {
            return Array(repeating: [], count: lines.count)
        }
        var state = State.normal
        return lines.map { line in
            let units = Array(line.utf16)
            var scopes: [SyntaxScope] = []
            var index = 0
            func matches(_ marker: [UInt16], at offset: Int) -> Bool {
                guard offset + marker.count <= units.count else { return false }
                for position in marker.indices where units[offset + position] != marker[position] {
                    return false
                }
                return true
            }
            func append(_ start: Int, _ end: Int, _ kind: SyntaxScopeKind) {
                if end > start { scopes.append(SyntaxScope(start: start, length: end - start, kind: kind)) }
            }
            while index < units.count {
                switch state {
                case .blockComment(let initialDepth):
                    let start = index
                    var depth = initialDepth
                    while index < units.count {
                        if (depth == 0 || dialect == .swift), matches([47, 42], at: index) {
                            depth += 1
                            index += 2
                        } else if matches([42, 47], at: index) {
                            depth -= 1
                            index += 2
                            if depth == 0 { break }
                        } else {
                            index += 1
                        }
                    }
                    append(start, index, .comment)
                    state = depth == 0 ? .normal : .blockComment(depth)
                case .xmlComment:
                    let start = index
                    while index < units.count, !matches([45, 45, 62], at: index) { index += 1 }
                    if index < units.count {
                        index += 3
                        state = .normal
                    }
                    append(start, index, .comment)
                case .multilineString(let delimiter):
                    let start = index
                    var closed = false
                    while index < units.count {
                        if units[index] == 92, index + 1 < units.count {
                            index += 2
                        } else if matches(delimiter, at: index) {
                            index += delimiter.count
                            closed = true
                            break
                        } else {
                            index += 1
                        }
                    }
                    append(start, index, .string)
                    if closed { state = .normal }
                case .normal:
                    if dialect == .xml, matches([60, 33, 45, 45], at: index) {
                        state = .xmlComment
                        index += 4
                        let start = index - 4
                        while index < units.count, !matches([45, 45, 62], at: index) { index += 1 }
                        if index < units.count { index += 3; state = .normal }
                        append(start, index, .comment)
                    } else if ([.swift, .javascript, .json].contains(dialect) &&
                               matches([47, 47], at: index)) ||
                                ([.python, .yaml, .shell].contains(dialect) && units[index] == 35) {
                        append(index, units.count, .comment)
                        index = units.count
                    } else if [.swift, .javascript, .json].contains(dialect), matches([47, 42], at: index) {
                        state = .blockComment(0)
                    } else if let delimiter = quote(at: index, units: units, dialect: dialect) {
                        let start = index
                        index += delimiter.count
                        let multiline = delimiter.count == 3 || delimiter == [96]
                        var closed = false
                        while index < units.count {
                            if units[index] == 92, index + 1 < units.count {
                                index += 2
                            } else if matches(delimiter, at: index) {
                                index += delimiter.count
                                closed = true
                                break
                            } else {
                                index += 1
                            }
                        }
                        append(start, index, .string)
                        if multiline && !closed { state = .multilineString(delimiter) }
                    } else {
                        index += 1
                    }
                }
            }
            return scopes
        }
    }

    private static func quote(at index: Int, units: [UInt16], dialect: SyntaxDialect) -> [UInt16]? {
        let value = units[index]
        if value == 34 {
            if [.swift, .python].contains(dialect), index + 2 < units.count,
               units[index + 1] == 34, units[index + 2] == 34 { return [34, 34, 34] }
            return [34]
        }
        if value == 39, [.javascript, .python, .xml, .yaml, .shell].contains(dialect) {
            if dialect == .python, index + 2 < units.count,
               units[index + 1] == 39, units[index + 2] == 39 { return [39, 39, 39] }
            return [39]
        }
        if value == 96, dialect == .javascript { return [96] }
        return nil
    }
}
