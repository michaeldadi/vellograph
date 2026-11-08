import Foundation

public enum FolderState: String, Sendable {
    case equal, different, onlyLeft, onlyRight
}

public enum FolderItemKind: String, Sendable {
    case file, directory, symbolicLink, other
}

public struct FolderDifference: Sendable, Identifiable {
    public let relativePath: String
    public let kind: FolderItemKind
    public let state: FolderState
    public var id: String { relativePath }
}

public struct FolderOptions: Sendable {
    public var includeHidden: Bool
    public var ignoredNames: Set<String>
    public var ignoredPathPatterns: [String]

    public init(
        includeHidden: Bool = false,
        ignoredNames: Set<String> = [".DS_Store"],
        ignoredPathPatterns: [String] = []
    ) {
        self.includeHidden = includeHidden
        self.ignoredNames = ignoredNames
        self.ignoredPathPatterns = ignoredPathPatterns
    }
}

public enum FolderComparison {
    struct Entry {
        let url: URL
        let kind: FolderItemKind
        let size: Int64
    }

    public static func compare(
        left: URL, right: URL, options: FolderOptions = .init()
    ) throws -> [FolderDifference] {
        let leftEntries = try scan(left, options: options)
        let rightEntries = try scan(right, options: options)
        let paths = Set(leftEntries.keys).union(rightEntries.keys).sorted()
        var result: [FolderDifference] = []
        for path in paths {
            try Task<Never, Never>.checkCancellation()
            let lhs = leftEntries[path]
            let rhs = rightEntries[path]
            let state: FolderState
            if lhs == nil { state = .onlyRight }
            else if rhs == nil { state = .onlyLeft }
            else if lhs!.kind != rhs!.kind { state = .different }
            else if lhs!.kind == .file {
                state = try lhs!.size == rhs!.size && filesEqual(lhs!.url, rhs!.url) ? .equal : .different
            } else if lhs!.kind == .symbolicLink {
                let a = try FileManager.default.destinationOfSymbolicLink(atPath: lhs!.url.path)
                let b = try FileManager.default.destinationOfSymbolicLink(atPath: rhs!.url.path)
                state = a == b ? .equal : .different
            } else {
                state = lhs!.kind == .directory ? .equal : .different
            }
            result.append(FolderDifference(relativePath: path, kind: lhs?.kind ?? rhs!.kind, state: state))
        }
        var changedDirectories = Set<String>()
        for entry in result where entry.state != .equal {
            var components = entry.relativePath.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                changedDirectories.insert(components.joined(separator: "/"))
            }
        }
        result = result.map { entry in
            guard entry.kind == .directory, entry.state == .equal,
                  changedDirectories.contains(entry.relativePath) else { return entry }
            return FolderDifference(relativePath: entry.relativePath, kind: entry.kind, state: .different)
        }
        return result
    }

    static func scan(_ root: URL, options: FolderOptions) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        let root = root.standardizedFileURL
        let ignoredPatterns = try options.ignoredPathPatterns.map { try NSRegularExpression(pattern: $0) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        func walk(_ directory: URL, prefix: String) throws {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
            for url in urls {
                try Task<Never, Never>.checkCancellation()
                let name = url.lastPathComponent
                if name.hasPrefix(".vellograph-") || options.ignoredNames.contains(name) ||
                    (!options.includeHidden && name.hasPrefix(".")) { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let range = NSRange(path.startIndex..<path.endIndex, in: path)
                if ignoredPatterns.contains(where: { $0.firstMatch(in: path, range: range) != nil }) { continue }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let kind: FolderItemKind
                if values.isSymbolicLink == true { kind = .symbolicLink }
                else if values.isDirectory == true { kind = .directory }
                else if values.fileSize != nil { kind = .file }
                else { kind = .other }
                result[path] = Entry(url: url, kind: kind, size: Int64(values.fileSize ?? 0))
                if kind == .directory { try walk(url, prefix: path) }
            }
        }
        try walk(root, prefix: "")
        return result
    }

    private static func filesEqual(_ left: URL, _ right: URL) throws -> Bool {
        let a = try FileHandle(forReadingFrom: left)
        let b = try FileHandle(forReadingFrom: right)
        defer { try? a.close(); try? b.close() }
        while true {
            try Task<Never, Never>.checkCancellation()
            let outcome = try autoreleasepool { () throws -> Bool? in
                let aBytes = try a.read(upToCount: 1_048_576) ?? Data()
                let bBytes = try b.read(upToCount: 1_048_576) ?? Data()
                if aBytes != bBytes { return false }
                if aBytes.isEmpty { return true }
                return nil
            }
            if let outcome { return outcome }
        }
    }
}

