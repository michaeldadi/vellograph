import Foundation

public struct TextReplacementFilter: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var pattern: String
    public var replacement: String
    public var enabled: Bool

    public init(id: UUID = UUID(), pattern: String, replacement: String = "", enabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.enabled = enabled
    }
}

public enum TextPreparationError: Error, LocalizedError, Equatable {
    case invalidPattern(String)
    case invalidJSON
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let pattern): "Invalid text filter pattern: \(pattern)"
        case .invalidJSON: "JSON normalization requires valid JSON on both sides."
        case .invalidUTF8: "The prepared text could not be encoded as UTF-8."
        }
    }
}

public struct TextPreparationOptions: Sendable {
    public var normalizeJSON: Bool
    public var filters: [TextReplacementFilter]

    public init(normalizeJSON: Bool = false, filters: [TextReplacementFilter] = []) {
        self.normalizeJSON = normalizeJSON
        self.filters = filters
    }
}

/// Produces display-only snapshots. The caller must retain the source snapshot
/// for any write operation, because filters can remove or reorder content.
public enum TextPreparation {
    public static func prepare(
        _ source: TextSnapshot, options: TextPreparationOptions
    ) throws -> TextSnapshot {
        var text = source.text
        for filter in options.filters where filter.enabled && !filter.pattern.isEmpty {
            try Task<Never, Never>.checkCancellation()
            guard let regex = try? NSRegularExpression(pattern: filter.pattern, options: [.anchorsMatchLines]) else {
                throw TextPreparationError.invalidPattern(filter.pattern)
            }
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: filter.replacement
            )
        }
        if options.normalizeJSON {
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let normalized = try? JSONSerialization.data(
                    withJSONObject: value,
                    options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  ),
                  let result = String(data: normalized, encoding: .utf8) else {
                throw TextPreparationError.invalidJSON
            }
            text = result + "\n"
        }
        return try TextSnapshot(text: text)
    }
}
