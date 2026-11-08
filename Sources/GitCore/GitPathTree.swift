import Foundation

public struct GitPathNode: Sendable, Identifiable, Equatable {
    public let path: String
    public let name: String
    public let isFile: Bool
    public let children: [GitPathNode]?

    public var id: String { path }
}

public enum GitPathTree {
    public static func build(paths: [String]) -> [GitPathNode] {
        var root = Builder()
        for path in Set(paths) where !path.isEmpty && !path.hasPrefix("/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { continue }
            root.insert(parts[...])
        }
        return root.nodes(prefix: "")
    }

    private struct Builder {
        var isFile = false
        var children: [String: Builder] = [:]

        mutating func insert(_ parts: ArraySlice<Substring>) {
            guard let first = parts.first else {
                isFile = true
                return
            }
            children[String(first), default: Builder()].insert(parts.dropFirst())
        }

        func nodes(prefix: String) -> [GitPathNode] {
            children.keys.sorted { left, right in
                let a = children[left]!
                let b = children[right]!
                if a.children.isEmpty != b.children.isEmpty { return !a.children.isEmpty }
                return left.localizedStandardCompare(right) == .orderedAscending
            }.map { name in
                let child = children[name]!
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return GitPathNode(path: path, name: name, isFile: child.isFile,
                                   children: child.children.isEmpty ? nil : child.nodes(prefix: path))
            }
        }
    }
}
