import Foundation

public enum DeepLinkError: Error, LocalizedError, Equatable {
    case unsupportedLink
    case invalidParameters

    public var errorDescription: String? {
        switch self {
        case .unsupportedLink: "Unsupported Vellograph link."
        case .invalidParameters: "This Vellograph link needs valid local paths and parameters."
        }
    }
}

/// The URL scheme accepts only local paths. It never fetches a source from a
/// network address or interprets a query value as a shell command.
public enum DeepLinkRequest: Sendable, Equatable {
    case compare(paths: [String])
    case history(repository: String)
    case changeset(repository: String, from: String, to: String)

    public static func parse(_ url: URL) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "vellograph",
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased() else {
            throw DeepLinkError.unsupportedLink
        }
        let items = components.queryItems ?? []
        switch host {
        case "compare", "diff":
            guard (1...2).contains(items.count), items.allSatisfy({ $0.name == "file" }) else {
                throw DeepLinkError.invalidParameters
            }
            return .compare(paths: try items.map { try localPath($0.value) })
        case "history":
            guard items.count == 1, items[0].name == "repo" else {
                throw DeepLinkError.invalidParameters
            }
            return .history(repository: try localPath(items[0].value))
        case "changeset":
            guard items.count == 3,
                  Set(items.map(\.name)) == ["repo", "from", "to"],
                  let repository = items.first(where: { $0.name == "repo" })?.value,
                  let from = items.first(where: { $0.name == "from" })?.value,
                  let to = items.first(where: { $0.name == "to" })?.value,
                  !from.isEmpty, !to.isEmpty else {
                throw DeepLinkError.invalidParameters
            }
            return .changeset(repository: try localPath(repository), from: from, to: to)
        default:
            throw DeepLinkError.unsupportedLink
        }
    }

    private static func localPath(_ value: String?) throws -> String {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else {
            throw DeepLinkError.invalidParameters
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
}
