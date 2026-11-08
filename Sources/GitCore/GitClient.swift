import Foundation

public enum GitError: Error, Sendable, CustomStringConvertible {
    case commandFailed(String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .commandFailed(let text), .invalidOutput(let text): text
        }
    }
}

public struct GitStatusEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character

    public var id: String { path }
    public var isUntracked: Bool { indexStatus == "?" }
    public var isPartiallyStaged: Bool { indexStatus != "." && worktreeStatus != "." }
}

public struct GitRepository: Sendable {
    public let root: URL
    public let gitDirectory: URL
    public let branch: String?
    public let status: [GitStatusEntry]
}

public struct GitClient: Sendable {
    public let executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executable = executable
    }

    public func repository(at path: URL) throws -> GitRepository {
        let rootString = try run(in: path, ["rev-parse", "--show-toplevel"]).trimmedLine
        let gitDirString = try run(in: path, ["rev-parse", "--absolute-git-dir"]).trimmedLine
        let root = URL(fileURLWithPath: rootString, isDirectory: true)
        let branch = try? run(in: root, ["symbolic-ref", "--quiet", "--short", "HEAD"]).trimmedLine
        return GitRepository(
            root: root,
            gitDirectory: URL(fileURLWithPath: gitDirString, isDirectory: true),
            branch: branch,
            status: try status(in: root)
        )
    }

    public func status(in root: URL) throws -> [GitStatusEntry] {
        let bytes = try run(in: root, ["status", "--porcelain=v2", "-z", "--untracked-files=all"])
        let records = bytes.split(separator: 0, omittingEmptySubsequences: true)
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = String(decoding: records[index], as: UTF8.self)
            index += 1
            if record.hasPrefix("? ") {
                entries.append(GitStatusEntry(path: String(record.dropFirst(2)), originalPath: nil, indexStatus: "?", worktreeStatus: "?"))
                continue
            }
            if record.hasPrefix("! ") { continue }
            let isRename = record.hasPrefix("2 ")
            guard record.hasPrefix("1 ") || isRename || record.hasPrefix("u ") else {
                throw GitError.invalidOutput("Unexpected Git status record")
            }
            let fieldCount = isRename ? 9 : record.hasPrefix("u ") ? 10 : 8
            let parts = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: true)
            guard parts.count == fieldCount + 1, parts[1].count == 2 else {
                throw GitError.invalidOutput("Malformed Git status record")
            }
            let xy = Array(parts[1])
            let original: String?
            if isRename {
                guard index < records.count else { throw GitError.invalidOutput("Missing rename source path") }
                original = String(decoding: records[index], as: UTF8.self)
                index += 1
            } else {
                original = nil
            }
            entries.append(GitStatusEntry(
                path: String(parts[fieldCount]),
                originalPath: original,
                indexStatus: xy[0],
                worktreeStatus: xy[1]
            ))
        }
        return entries
    }

    public func changedPaths(in root: URL, from left: String, to right: String) throws -> [String] {
        let leftID = try resolveCommit(in: root, ref: left)
        let rightID = try resolveCommit(in: root, ref: right)
        let data = try run(in: root, ["diff", "--no-ext-diff", "--name-only", "-z", "--find-renames", leftID, rightID, "--"])
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    public func resolveCommit(in root: URL, ref: String) throws -> String {
        guard !ref.isEmpty, !ref.contains("\0"), !ref.contains("\n") else {
            throw GitError.invalidOutput("Invalid revision")
        }
        let id = try run(in: root, ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"]).trimmedLine
        guard (id.count == 40 || id.count == 64), id.allSatisfy(\.isHexDigit) else {
            throw GitError.invalidOutput("Invalid resolved revision")
        }
        return id
    }

    public func fileHistory(in root: URL, path: String, limit: Int = 100) throws -> [String] {
        guard limit > 0 else { return [] }
        let data = try run(in: root, ["log", "-z", "--format=%H", "-n", String(limit), "--", path])
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func blob(in root: URL, objectID: String) throws -> Data {
        guard objectID.count == 40 || objectID.count == 64,
              objectID.allSatisfy({ $0.isHexDigit }) else {
            throw GitError.invalidOutput("Invalid object identifier")
        }
        return try run(in: root, ["cat-file", "blob", objectID])
    }

    @discardableResult
    public func run(in directory: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(String(decoding: data.prefix(2_000), as: UTF8.self))
        }
        return data
    }
}

private extension Data {
    var trimmedLine: String {
        String(decoding: self, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

