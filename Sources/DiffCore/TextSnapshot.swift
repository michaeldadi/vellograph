import Foundation

public enum TextEncoding: String, Sendable, Codable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        }
    }
}

public enum SnapshotError: Error, Equatable {
    case unsupportedEncoding
    case binaryContent
    case failedToEncode
}

public struct TextLine: Hashable, Sendable {
    public let content: String
    public let ending: String

    public init(content: String, ending: String) {
        self.content = content
        self.ending = ending
    }

    public var fullText: String { content + ending }
}

public struct TextSnapshot: Sendable {
    public let lines: [TextLine]
    public let encoding: TextEncoding
    public let hasByteOrderMark: Bool
    public let originalData: Data

    public var text: String { lines.map(\.fullText).joined() }

    public init(data: Data) throws {
        let prefix = Array(data.prefix(3))
        let encoding: TextEncoding
        let bomLength: Int
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
            bomLength = 3
        } else if prefix.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            bomLength = 2
        } else if prefix.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            bomLength = 2
        } else {
            encoding = .utf8
            bomLength = 0
            if data.contains(0) { throw SnapshotError.binaryContent }
        }
        let payload = data.dropFirst(bomLength)
        guard let value = String(data: Data(payload), encoding: encoding.foundationEncoding) else {
            throw SnapshotError.unsupportedEncoding
        }
        self.lines = Self.lines(in: value)
        self.encoding = encoding
        self.hasByteOrderMark = bomLength > 0
        self.originalData = data
    }

    public init(text: String, encoding: TextEncoding = .utf8, hasByteOrderMark: Bool = false) throws {
        self.lines = Self.lines(in: text)
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
        guard let data = Self.encode(text, encoding: encoding, bom: hasByteOrderMark) else {
            throw SnapshotError.failedToEncode
        }
        self.originalData = data
    }

    public func encode(_ lines: [TextLine]) throws -> Data {
        guard let data = Self.encode(lines.map(\.fullText).joined(), encoding: encoding, bom: hasByteOrderMark) else {
            throw SnapshotError.failedToEncode
        }
        return data
    }

    private static func encode(_ value: String, encoding: TextEncoding, bom: Bool) -> Data? {
        guard let body = value.data(using: encoding.foundationEncoding) else { return nil }
        guard bom else { return body }
        var prefix: [UInt8]
        switch encoding {
        case .utf8: prefix = [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: prefix = [0xFF, 0xFE]
        case .utf16BigEndian: prefix = [0xFE, 0xFF]
        }
        return Data(prefix) + body
    }

    private static func lines(in value: String) -> [TextLine] {
        guard !value.isEmpty else { return [] }
        let text = value as NSString
        var result: [TextLine] = []
        var position = 0
        while position < text.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            result.append(TextLine(
                content: text.substring(with: NSRange(location: start, length: contentsEnd - start)),
                ending: text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
            ))
            position = end
        }
        return result
    }
}

