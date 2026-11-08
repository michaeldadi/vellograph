import Foundation
import DiffCore

public enum GitError: Error, Sendable, LocalizedError, CustomStringConvertible {
    case commandFailed(String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .commandFailed(let text), .invalidOutput(let text): text
        }
    }

    public var errorDescription: String? { description }
}

public struct GitStatusEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character

    public var id: String { path }
    public var isUntracked: Bool { indexStatus == "?" }
    public var isUnmerged: Bool {
        "ADU".contains(indexStatus) && "ADU".contains(worktreeStatus) &&
        (indexStatus == "U" || worktreeStatus == "U" ||
         (indexStatus == "A" && worktreeStatus == "A") ||
         (indexStatus == "D" && worktreeStatus == "D"))
    }
    public var isPartiallyStaged: Bool {
        !isUntracked && !isUnmerged && indexStatus != "." && worktreeStatus != "."
    }
}

public struct GitConflictStages: Sendable, Equatable {
    public let base: Data?
    public let ours: Data?
    public let theirs: Data?
}

/// Git trees store submodules as commit pointers rather than file blobs.
/// A nil gitlink commit means that an initialized working tree is unavailable.
public enum GitFileItem: Sendable, Equatable {
    case blob(Data)
    case gitlink(String?)
}

public struct GitLFSPointer: Sendable, Equatable {
    public let objectID: String
    public let size: UInt64

    public static func parse(_ data: Data) -> GitLFSPointer? {
        guard data.count <= 1_024, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "version https://git-lfs.github.com/spec/v1",
              let oidLine = lines.first(where: { $0.hasPrefix("oid sha256:") }),
              let sizeLine = lines.first(where: { $0.hasPrefix("size ") }) else { return nil }
        let objectID = String(oidLine.dropFirst("oid sha256:".count))
        guard objectID.count == 64, objectID.allSatisfy(\.isHexDigit),
              let size = UInt64(sizeLine.dropFirst("size ".count)) else { return nil }
        return GitLFSPointer(objectID: objectID, size: size)
    }
}

public enum GitWholeFileChoice: Sendable, Equatable {
    case ours
    case theirs
    case delete
}

public struct GitRepository: Sendable {
    public let root: URL
    public let gitDirectory: URL
    public let branch: String?
    public let status: [GitStatusEntry]
}

public struct GitWorktree: Sendable, Identifiable {
    public let root: URL
    public let head: String?
    public let branch: String?
    public let isDetached: Bool

    public var id: String { root.path }
}

public struct GitCommit: Sendable, Identifiable, Equatable {
    public let id: String
    public let parents: [String]
    public let timestamp: Date
    public let subject: String
}

public struct GitPathChange: Sendable, Identifiable, Equatable {
    public let path: String
    public let originalPath: String?
    public let status: String

    public var id: String { path }
}

public struct GitFileRevision: Sendable, Identifiable {
    public let commit: GitCommit
    public let path: String
    public let parentPath: String

    public var id: String { commit.id }
}

public struct GitRef: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case branch = "Branch"
        case remote = "Remote"
        case tag = "Tag"
    }

    public let name: String
    public let commitID: String
    public let kind: Kind

    public var id: String { name }
    public var displayName: String {
        switch kind {
        case .branch: String(name.dropFirst("refs/heads/".count))
        case .remote: String(name.dropFirst("refs/remotes/".count))
        case .tag: String(name.dropFirst("refs/tags/".count))
        }
    }
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

    public func worktrees(in root: URL) throws -> [GitWorktree] {
        let bytes = try run(in: root, ["worktree", "list", "--porcelain", "-z"])
        let records = bytes.split(separator: 0, omittingEmptySubsequences: false)
        var worktrees: [GitWorktree] = []
        var path: String?
        var head: String?
        var branch: String?
        var detached = false
        for record in records {
            let field = String(decoding: record, as: UTF8.self)
            if field.isEmpty {
                if let path {
                    worktrees.append(GitWorktree(root: URL(fileURLWithPath: path, isDirectory: true),
                                                 head: head, branch: branch, isDetached: detached))
                }
                path = nil
                head = nil
                branch = nil
                detached = false
            } else if field.hasPrefix("worktree ") {
                path = String(field.dropFirst(9))
            } else if field.hasPrefix("HEAD ") {
                let value = String(field.dropFirst(5))
                guard validObjectID(value) else { throw GitError.invalidOutput("Malformed Git worktree HEAD") }
                head = value
            } else if field.hasPrefix("branch ") {
                branch = String(field.dropFirst(7))
            } else if field == "detached" {
                detached = true
            }
        }
        return worktrees
    }

    public func changedPaths(in root: URL, from left: String, to right: String) throws -> [String] {
        try changes(in: root, from: left, to: right).map(\.path)
    }

    public func changes(in root: URL, from left: String, to right: String) throws -> [GitPathChange] {
        let leftID = try resolveCommit(in: root, ref: left)
        let rightID = try resolveCommit(in: root, ref: right)
        let data = try run(in: root, ["diff", "--no-ext-diff", "--name-status", "-z",
                                      "--find-renames", leftID, rightID, "--"])
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var changes: [GitPathChange] = []
        var index = 0
        while index < records.count {
            let status = String(decoding: records[index], as: UTF8.self)
            index += 1
            guard !status.isEmpty, "ADMRTCU".contains(status.first!) else {
                throw GitError.invalidOutput("Unexpected Git change status")
            }
            let renamed = status.hasPrefix("R") || status.hasPrefix("C")
            guard index + (renamed ? 1 : 0) < records.count else {
                throw GitError.invalidOutput("Missing Git change path")
            }
            let first = String(decoding: records[index], as: UTF8.self)
            index += 1
            let path: String
            let original: String?
            if renamed {
                original = first
                path = String(decoding: records[index], as: UTF8.self)
                index += 1
            } else {
                original = nil
                path = first
            }
            guard validRelativePath(path), original.map(validRelativePath) ?? true else {
                throw GitError.invalidOutput("Invalid Git change path")
            }
            changes.append(GitPathChange(path: path, originalPath: original, status: status))
        }
        return changes
    }

    public func commitHistory(in root: URL, limit: Int = 100) throws -> [GitCommit] {
        guard limit > 0 else { return [] }
        let bytes = try run(in: root, ["log", "--format=%H%x1f%P%x1f%at%x1f%s%x1e",
                                       "--all", "--topo-order", "-n", String(min(limit, 1_000))])
        return try parseCommits(bytes)
    }

    public func refs(in root: URL) throws -> [GitRef] {
        let bytes = try run(in: root, ["for-each-ref",
                                       "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)",
                                       "refs/heads", "refs/remotes", "refs/tags"])
        return try String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> GitRef? in
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count == 5 else {
                    throw GitError.invalidOutput("Malformed Git reference")
                }
                let name = String(fields[0])
                let object = String(fields[1])
                let objectType = String(fields[2])
                let peeled = String(fields[3])
                let peeledType = String(fields[4])
                let kind: GitRef.Kind
                if name.hasPrefix("refs/heads/") { kind = .branch }
                else if name.hasPrefix("refs/remotes/") { kind = .remote }
                else if name.hasPrefix("refs/tags/") { kind = .tag }
                else { throw GitError.invalidOutput("Unexpected Git reference") }
                let target = peeled.isEmpty ? object : peeled
                let targetType = peeled.isEmpty ? objectType : peeledType
                // A tag can target a tree or blob. It cannot be shown as a commit label.
                guard validObjectID(target) else {
                    throw GitError.invalidOutput("Malformed Git reference target")
                }
                return targetType == "commit" ? GitRef(name: name, commitID: target, kind: kind) : nil
            }
    }

    public func fileRevisions(in root: URL, path: String, at ref: String = "HEAD",
                              limit: Int = 100) throws -> [GitFileRevision] {
        guard validRelativePath(path) else { throw GitError.invalidOutput("Invalid file history path") }
        guard limit > 0 else { return [] }
        let commitID = try resolveCommit(in: root, ref: ref)
        let bytes = try run(in: root, ["log", "--follow",
                                       "--format=%H%x1f%P%x1f%at%x1f%s%x1e",
                                       "-n", String(min(limit, 1_000)), commitID, "--", path])
        let commits = try parseCommits(bytes)
        var currentPath = path
        var revisions: [GitFileRevision] = []
        for commit in commits {
            try Task<Never, Never>.checkCancellation()
            var parentPath = currentPath
            if let parent = commit.parents.first {
                let change = try changes(in: root, from: parent, to: commit.id)
                    .first { $0.path == currentPath }
                if let original = change?.originalPath { parentPath = original }
            }
            revisions.append(GitFileRevision(commit: commit, path: currentPath,
                                             parentPath: parentPath))
            currentPath = parentPath
        }
        return revisions
    }

    private func parseCommits(_ bytes: Data) throws -> [GitCommit] {
        let records = bytes.split(separator: 0x1e).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines)
        }.filter { !$0.isEmpty }
        return try records.map { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 4 else { throw GitError.invalidOutput("Malformed Git commit history") }
            let id = String(fields[0])
            let parentText = String(fields[1])
            let timestampText = String(fields[2])
            let subject = String(fields[3])
            guard validObjectID(id), let seconds = TimeInterval(timestampText) else {
                throw GitError.invalidOutput("Malformed Git commit record")
            }
            let parents = parentText.split(separator: " ").map(String.init)
            guard parents.allSatisfy(validObjectID) else {
                throw GitError.invalidOutput("Malformed Git parent record")
            }
            return GitCommit(id: id, parents: parents, timestamp: Date(timeIntervalSince1970: seconds),
                             subject: subject)
        }
    }

    public func changedPaths(in root: URL, for commit: GitCommit) throws -> [String] {
        let data: Data
        if let parent = commit.parents.first {
            data = try run(in: root, ["diff", "--no-ext-diff", "--name-only", "-z",
                                      "--find-renames", parent, commit.id, "--"])
        } else {
            data = try run(in: root, ["diff-tree", "--root", "--no-commit-id", "--name-only",
                                      "-r", "-z", commit.id])
        }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    public func treeItem(in root: URL, at commitID: String, path: String) throws -> GitFileItem? {
        guard validObjectID(commitID), validRelativePath(path) else {
            throw GitError.invalidOutput("Invalid Git file request")
        }
        let records = try run(in: root, ["ls-tree", "-z", commitID, "--", path])
            .split(separator: 0, omittingEmptySubsequences: true)
        guard let record = records.first else { return nil }
        let parts = record.split(separator: 9, maxSplits: 1)
        guard parts.count == 2, String(decoding: parts[1], as: UTF8.self) == path else {
            throw GitError.invalidOutput("Unexpected Git tree path")
        }
        let header = String(decoding: parts[0], as: UTF8.self).split(separator: " ")
        guard header.count == 3, validObjectID(String(header[2])) else {
            throw GitError.invalidOutput("Malformed Git tree item")
        }
        if header[0] == "160000", header[1] == "commit" {
            return .gitlink(String(header[2]))
        }
        guard header[1] == "blob" else {
            throw GitError.invalidOutput("Git tree item is neither a file nor a submodule")
        }
        return .blob(try blob(in: root, objectID: String(header[2])))
    }

    public func file(in root: URL, at commitID: String, path: String) throws -> Data? {
        guard let item = try treeItem(in: root, at: commitID, path: path) else { return nil }
        guard case .blob(let data) = item else {
            throw GitError.invalidOutput("Git path is a submodule commit, not a file blob")
        }
        return data
    }

    public func headFile(in root: URL, path: String) throws -> Data? {
        guard validRelativePath(path) else { throw GitError.invalidOutput("Invalid Git file path") }
        guard let commit = try? resolveCommit(in: root, ref: "HEAD") else { return nil }
        return try file(in: root, at: commit, path: path)
    }

    public func indexItem(in root: URL, path: String) throws -> GitFileItem? {
        guard validRelativePath(path) else { throw GitError.invalidOutput("Invalid Git file path") }
        let records = try run(in: root, ["ls-files", "--stage", "-z", "--", path])
            .split(separator: 0, omittingEmptySubsequences: true)
        guard !records.isEmpty else { return nil }
        let matching = try records.compactMap { record -> GitFileItem? in
            let parts = record.split(separator: 9, maxSplits: 1)
            guard parts.count == 2, String(decoding: parts[1], as: UTF8.self) == path else {
                throw GitError.invalidOutput("Unexpected Git index path")
            }
            let header = String(decoding: parts[0], as: UTF8.self).split(separator: " ")
            guard header.count == 3, validObjectID(String(header[1])) else {
                throw GitError.invalidOutput("Malformed Git index record")
            }
            guard header[2] == "0" else { return nil }
            if header[0] == "160000" { return .gitlink(String(header[1])) }
            return .blob(try blob(in: root, objectID: String(header[1])))
        }
        guard let item = matching.first else {
            throw GitError.invalidOutput("Unmerged Git index stages need conflict resolution")
        }
        return item
    }

    public func indexFile(in root: URL, path: String) throws -> Data? {
        guard let item = try indexItem(in: root, path: path) else { return nil }
        guard case .blob(let data) = item else {
            throw GitError.invalidOutput("Git index path is a submodule commit, not a file blob")
        }
        return data
    }

    /// Returns the index's common base, ours, and theirs blobs for an unmerged path.
    /// A missing stage represents a deletion on that side, not a read failure.
    public func conflictStages(in root: URL, path: String) throws -> GitConflictStages? {
        guard validRelativePath(path) else { throw GitError.invalidOutput("Invalid Git conflict path") }
        let records = try run(in: root, ["ls-files", "--unmerged", "-z", "--", path])
            .split(separator: 0, omittingEmptySubsequences: true)
        guard !records.isEmpty else { return nil }
        var objects: [Int: String] = [:]
        for record in records {
            let parts = record.split(separator: 9, maxSplits: 1)
            guard parts.count == 2, String(decoding: parts[1], as: UTF8.self) == path else {
                throw GitError.invalidOutput("Unexpected Git conflict path")
            }
            let header = String(decoding: parts[0], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let stage = Int(header[2]), (1...3).contains(stage),
                  validObjectID(String(header[1])), objects[stage] == nil else {
                throw GitError.invalidOutput("Malformed Git conflict stage")
            }
            objects[stage] = String(header[1])
        }
        return try GitConflictStages(base: objects[1].map { try blob(in: root, objectID: $0) },
                                     ours: objects[2].map { try blob(in: root, objectID: $0) },
                                     theirs: objects[3].map { try blob(in: root, objectID: $0) })
    }

    /// Saves a whole-file resolution for binary and add/delete conflicts. Git's
    /// index remains unmerged until the user explicitly stages the result.
    public func saveWholeFileConflict(in root: URL, path: String,
                                      expectedStages: GitConflictStages,
                                      expectedWorkingFile: Data?,
                                      choice: GitWholeFileChoice) throws -> TextWriteResult {
        guard let currentStages = try conflictStages(in: root, path: path),
              currentStages == expectedStages else {
            throw GitError.invalidOutput("The Git conflict changed after it was opened. Reopen it before saving.")
        }
        let destination = root.appendingPathComponent(path)
        let chosen: Data?
        switch choice {
        case .ours: chosen = expectedStages.ours
        case .theirs: chosen = expectedStages.theirs
        case .delete: chosen = nil
        }
        guard let chosen else {
            return try SafeTextWrite.delete(at: destination, expected: expectedWorkingFile)
        }
        if let expectedWorkingFile {
            return try SafeTextWrite.replace(at: destination, expected: expectedWorkingFile, with: chosen)
        }
        try SafeTextWrite.create(at: destination, data: chosen)
        return TextWriteResult(recoveryURL: nil)
    }

    public func workingItem(in root: URL, path: String) throws -> GitFileItem? {
        guard validRelativePath(path) else { throw GitError.invalidOutput("Invalid Git file path") }
        let url = root.appendingPathComponent(path)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.code == NSFileNoSuchFileError { return nil }
        let kind = attributes[.type] as? FileAttributeType
        if let indexed = try? indexItem(in: root, path: path), case .gitlink = indexed {
            guard kind == .typeDirectory else {
                throw GitError.invalidOutput("The submodule working path is not a directory")
            }
            let topLevel = try? run(in: url, ["rev-parse", "--show-toplevel"]).trimmedLine
            guard let topLevel,
                  URL(fileURLWithPath: topLevel).resolvingSymlinksInPath().standardizedFileURL ==
                  url.resolvingSymlinksInPath().standardizedFileURL else { return .gitlink(nil) }
            let commit = try? resolveCommit(in: url, ref: "HEAD")
            return .gitlink(commit)
        }
        if kind == .typeSymbolicLink {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return .blob(Data(target.utf8))
        }
        guard kind == .typeRegular else {
            throw GitError.invalidOutput("The selected working-copy item is not a regular file")
        }
        return .blob(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func workingFile(in root: URL, path: String) throws -> Data? {
        guard let item = try workingItem(in: root, path: path) else { return nil }
        guard case .blob(let data) = item else {
            throw GitError.invalidOutput("Git working path is a submodule, not a file blob")
        }
        return data
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

    private func validObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
        !path.split(separator: "/").contains("..")
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

