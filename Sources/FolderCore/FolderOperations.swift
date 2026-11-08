import CryptoKit
import Darwin
import Foundation

public enum FolderOperationError: Error, LocalizedError, Equatable {
    case invalidRoots
    case noSelection
    case unsupportedItem(String)
    case unsafeSymbolicLink(String)
    case unsafeDestination(String)
    case stalePreview(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoots: "Choose two separate folders that are not nested inside each other."
        case .noSelection: "Select at least one source item to copy."
        case .unsupportedItem(let path): "This item needs manual handling before copying: \(path)"
        case .unsafeSymbolicLink(let path): "This symbolic link leaves the compared folder: \(path)"
        case .unsafeDestination(let path): "The destination path passes through a symbolic link: \(path)"
        case .stalePreview(let path): "The folders changed after preview. Review the operation again: \(path)"
        case .rollbackFailed(let path): "Automatic rollback was incomplete. Recovery files remain at \(path)."
        }
    }
}

public enum FolderOperationMode: String, Sendable {
    case copy = "Copy Selected"
    case clone = "Clone Visible Scope"
}

public enum FolderActionKind: String, Sendable {
    case createDirectory = "Create Folder"
    case create = "Copy"
    case replace = "Replace"
    case remove = "Remove"
}

public struct FolderAction: Sendable, Identifiable {
    public let path: String
    public let kind: FolderActionKind
    public let itemKind: FolderItemKind
    public var id: String { "\(kind.rawValue):\(path)" }

    let sourceFingerprint: FolderFingerprint?
    let destinationFingerprint: FolderFingerprint?
}

struct FolderFingerprint: Sendable, Equatable {
    let kind: FolderItemKind
    let digest: [UInt8]?
}

private struct FolderRootIdentity: Sendable, Equatable {
    let resolvedPath: String
    let device: UInt64
    let inode: UInt64
}

public struct FolderApplyResult: Sendable {
    public let appliedCount: Int
    public let recoveryFolder: URL?
}

public struct FolderOperationPlan: Sendable {
    public let sourceRoot: URL
    public let destinationRoot: URL
    public let mode: FolderOperationMode
    public let actions: [FolderAction]

    private let options: FolderOptions
    private let sourcePaths: Set<String>
    private let destinationPaths: Set<String>
    private let sourceIdentity: FolderRootIdentity
    private let destinationIdentity: FolderRootIdentity

    public static func makeCopy(
        from source: URL, to destination: URL,
        selectedPaths: Set<String>, options: FolderOptions = .init()
    ) throws -> Self {
        guard !selectedPaths.isEmpty else { throw FolderOperationError.noSelection }
        return try build(from: source, to: destination, mode: .copy,
                         selectedPaths: selectedPaths, options: options)
    }

    public static func makeClone(
        from source: URL, to destination: URL,
        options: FolderOptions = .init()
    ) throws -> Self {
        try build(from: source, to: destination, mode: .clone,
                  selectedPaths: [], options: options)
    }

    private static func build(
        from source: URL, to destination: URL, mode: FolderOperationMode,
        selectedPaths: Set<String>, options: FolderOptions
    ) throws -> Self {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        try validateRoots(source, destination)
        let sourceIdentity = try rootIdentity(source)
        let destinationIdentity = try rootIdentity(destination)
        let sourceEntries = try FolderComparison.scan(source, options: options)
        let destinationEntries = try FolderComparison.scan(destination, options: options)
        let packages = try packagePaths(in: source, entries: sourceEntries)
            .union(packagePaths(in: destination, entries: destinationEntries))
        let included: [String]
        if mode == .clone {
            included = sourceEntries.keys.sorted()
        } else {
            let selected = sourceEntries.keys.filter { path in
                selectedPaths.contains(path) || selectedPaths.contains(where: { path.hasPrefix($0 + "/") })
            }
            var expanded = Set(selected)
            for path in selected {
                var components = path.split(separator: "/").map(String.init)
                while components.count > 1 {
                    components.removeLast()
                    let parent = components.joined(separator: "/")
                    if sourceEntries[parent]?.kind == .directory { expanded.insert(parent) }
                }
            }
            included = expanded.sorted()
            guard !included.isEmpty else { throw FolderOperationError.noSelection }
        }

        var actions: [FolderAction] = []
        for path in included {
            try Task<Never, Never>.checkCancellation()
            try validatePackagePath(path, against: packages)
            guard let sourceEntry = sourceEntries[path] else { continue }
            guard sourceEntry.kind != .other else { throw FolderOperationError.unsupportedItem(path) }
            try validateSymbolicLink(sourceEntry, sourceRoot: source,
                                     destinationRoot: destination, path: path)
            let destinationEntry = destinationEntries[path]
            let sourceFingerprint = try fingerprint(sourceEntry)
            let destinationFingerprint = try destinationEntry.map(fingerprint)
            if let destinationEntry, destinationEntry.kind != sourceEntry.kind {
                throw FolderOperationError.unsupportedItem(path)
            }
            if sourceEntry.kind == .directory {
                if destinationEntry == nil {
                    actions.append(FolderAction(path: path, kind: .createDirectory,
                                                itemKind: .directory,
                                                sourceFingerprint: sourceFingerprint,
                                                destinationFingerprint: nil))
                }
            } else if destinationEntry == nil {
                actions.append(FolderAction(path: path, kind: .create,
                                            itemKind: sourceEntry.kind,
                                            sourceFingerprint: sourceFingerprint,
                                            destinationFingerprint: nil))
            } else if sourceFingerprint != destinationFingerprint {
                actions.append(FolderAction(path: path, kind: .replace,
                                            itemKind: sourceEntry.kind,
                                            sourceFingerprint: sourceFingerprint,
                                            destinationFingerprint: destinationFingerprint))
            }
        }
        if mode == .clone {
            for path in destinationEntries.keys.sorted() where sourceEntries[path] == nil {
                try validatePackagePath(path, against: packages)
                guard let entry = destinationEntries[path], entry.kind != .other else {
                    throw FolderOperationError.unsupportedItem(path)
                }
                actions.append(FolderAction(path: path, kind: .remove,
                                            itemKind: entry.kind, sourceFingerprint: nil,
                                            destinationFingerprint: try fingerprint(entry)))
            }
            // Hidden and ignored descendants are outside the visible clone scope.
            // Keep their containing directories so a preview never implies that
            // excluded content will be deleted or moved into recovery.
            let protected = try excludedDescendantDirectories(
                in: destination, visiblePaths: Set(destinationEntries.keys))
            actions.removeAll { $0.kind == .remove && $0.itemKind == .directory &&
                protected.contains($0.path) }
        }
        actions.sort { lhs, rhs in
            let leftRank = rank(lhs.kind)
            let rightRank = rank(rhs.kind)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftDepth = lhs.path.split(separator: "/").count
            let rightDepth = rhs.path.split(separator: "/").count
            if leftDepth != rightDepth {
                return lhs.kind == .remove ? leftDepth > rightDepth : leftDepth < rightDepth
            }
            return lhs.path < rhs.path
        }
        return Self(sourceRoot: source, destinationRoot: destination, mode: mode,
                    actions: actions, options: options,
                    sourcePaths: Set(sourceEntries.keys), destinationPaths: Set(destinationEntries.keys),
                    sourceIdentity: sourceIdentity, destinationIdentity: destinationIdentity)
    }

    public func apply() throws -> FolderApplyResult {
        try apply(afterFinalTargetCheck: nil)
    }

    // The hook lets tests exercise a change in the narrow interval between
    // the final fingerprint and the filesystem move.
    func apply(afterFinalTargetCheck: ((FolderAction) throws -> Void)?) throws -> FolderApplyResult {
        try preflight()
        guard !actions.isEmpty else { return FolderApplyResult(appliedCount: 0, recoveryFolder: nil) }
        let fm = FileManager.default
        let identifier = UUID().uuidString
        let parent = destinationRoot.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".vellograph-stage-\(identifier)", isDirectory: true)
        let recovery = parent.appendingPathComponent(".vellograph-recovery-\(identifier)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }

        // Copy every source item before touching the destination. A failed
        // source read therefore leaves destination contents unchanged.
        for action in actions where action.kind == .create || action.kind == .replace {
            let staged = stage.appendingPathComponent(action.path)
            try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: sourceRoot.appendingPathComponent(action.path), to: staged)
            guard try Self.fingerprintAt(staged) == action.sourceFingerprint else {
                throw FolderOperationError.stalePreview(action.path)
            }
        }
        try preflight()
        try fm.createDirectory(at: recovery, withIntermediateDirectories: false)
        struct Applied {
            let path: String
            let backup: URL?
            let restoreDirectory: Bool
            let createdDirectory: Bool
            let restorePermissions: NSNumber?
            var installedFingerprint: FolderFingerprint?
        }
        var applied: [Applied] = []
        do {
            for action in actions {
                try Task<Never, Never>.checkCancellation()
                try validateRootIdentities()
                let target = destinationRoot.appendingPathComponent(action.path)
                try Self.validateDestinationParents(destinationRoot, path: action.path)
                if action.itemKind == .symbolicLink && action.kind != .remove {
                    try Self.validateSymbolicLink(
                        FolderComparison.Entry(url: sourceRoot.appendingPathComponent(action.path),
                                               kind: .symbolicLink, size: 0),
                        sourceRoot: sourceRoot, destinationRoot: destinationRoot,
                        path: action.path)
                }
                guard try Self.fingerprintAt(target) == action.destinationFingerprint else {
                    throw FolderOperationError.stalePreview(action.path)
                }
                try afterFinalTargetCheck?(action)
                if action.kind == .remove, action.itemKind == .directory {
                    // rmdir is atomic and fails if an excluded or newly arrived
                    // child exists. Moving the whole directory would silently
                    // remove such a child from the user's visible scope.
                    let permissions = try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
                    guard Darwin.rmdir(target.path) == 0 else {
                        throw FolderOperationError.stalePreview(action.path)
                    }
                    applied.append(Applied(path: action.path, backup: nil,
                                           restoreDirectory: true, createdDirectory: false,
                                           restorePermissions: permissions, installedFingerprint: nil))
                    continue
                }
                let backup: URL?
                if action.destinationFingerprint != nil {
                    let saved = recovery.appendingPathComponent(action.path)
                    try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: target, to: saved)
                    backup = saved
                } else {
                    backup = nil
                }
                applied.append(Applied(path: action.path, backup: backup,
                                       restoreDirectory: false,
                                       createdDirectory: action.kind == .createDirectory,
                                       restorePermissions: nil, installedFingerprint: nil))
                if let backup, try Self.fingerprintAt(backup) != action.destinationFingerprint {
                    throw FolderOperationError.stalePreview(action.path)
                }
                switch action.kind {
                case .createDirectory:
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                case .create, .replace:
                    try fm.moveItem(at: stage.appendingPathComponent(action.path), to: target)
                case .remove: break
                }
                applied[applied.count - 1].installedFingerprint = action.kind == .remove
                    ? nil : action.sourceFingerprint
            }
        } catch {
            var rollbackFailed = false
            for operation in applied.reversed() {
                let target = destinationRoot.appendingPathComponent(operation.path)
                do {
                    let current = try Self.fingerprintAt(target)
                    guard current == operation.installedFingerprint else {
                        throw FolderOperationError.rollbackFailed(recovery.path)
                    }
                    if current != nil {
                        if operation.createdDirectory {
                            guard Darwin.rmdir(target.path) == 0 else {
                                throw FolderOperationError.rollbackFailed(recovery.path)
                            }
                        } else {
                            try fm.removeItem(at: target)
                        }
                    }
                    if operation.restoreDirectory {
                        let attributes = operation.restorePermissions.map {
                            [FileAttributeKey.posixPermissions: $0]
                        }
                        try fm.createDirectory(at: target, withIntermediateDirectories: false,
                                               attributes: attributes)
                    }
                    if let backup = operation.backup {
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: backup, to: target)
                    }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw FolderOperationError.rollbackFailed(recovery.path) }
            try? fm.removeItem(at: recovery)
            throw error
        }
        let retained = applied.contains { $0.backup != nil } ? recovery : nil
        if retained == nil { try? fm.removeItem(at: recovery) }
        return FolderApplyResult(appliedCount: actions.count, recoveryFolder: retained)
    }

    private func preflight() throws {
        try Self.validateRoots(sourceRoot, destinationRoot)
        try validateRootIdentities()
        let currentSource = try FolderComparison.scan(sourceRoot, options: options)
        let currentDestination = try FolderComparison.scan(destinationRoot, options: options)
        let packages = try Self.packagePaths(in: sourceRoot, entries: currentSource)
            .union(Self.packagePaths(in: destinationRoot, entries: currentDestination))
        guard Set(currentSource.keys) == sourcePaths, Set(currentDestination.keys) == destinationPaths else {
            throw FolderOperationError.stalePreview("folder contents")
        }
        for action in actions {
            try Self.validatePackagePath(action.path, against: packages)
            let source = try currentSource[action.path].map(Self.fingerprint)
            let destination = try currentDestination[action.path].map(Self.fingerprint)
            guard source == action.sourceFingerprint, destination == action.destinationFingerprint else {
                throw FolderOperationError.stalePreview(action.path)
            }
            if let sourceEntry = currentSource[action.path], sourceEntry.kind == .symbolicLink {
                try Self.validateSymbolicLink(sourceEntry, sourceRoot: sourceRoot,
                                              destinationRoot: destinationRoot, path: action.path)
            }
            try Self.validateDestinationParents(destinationRoot, path: action.path)
        }
    }

    private func validateRootIdentities() throws {
        guard try Self.rootIdentity(sourceRoot) == sourceIdentity,
              try Self.rootIdentity(destinationRoot) == destinationIdentity else {
            throw FolderOperationError.stalePreview("folder roots")
        }
    }

    private static func rank(_ kind: FolderActionKind) -> Int {
        switch kind {
        case .createDirectory: 0
        case .create, .replace: 1
        case .remove: 2
        }
    }

    private static func excludedDescendantDirectories(
        in root: URL, visiblePaths: Set<String>
    ) throws -> Set<String> {
        var protected: Set<String> = []
        func walk(_ directory: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [])
            for child in children {
                try Task<Never, Never>.checkCancellation()
                let path = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                if !visiblePaths.contains(path) {
                    var ancestor = prefix
                    while !ancestor.isEmpty {
                        protected.insert(ancestor)
                        ancestor = ancestor.split(separator: "/").dropLast().joined(separator: "/")
                    }
                    continue
                }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    try walk(child, prefix: path)
                }
            }
        }
        try walk(root, prefix: "")
        return protected
    }

    private static func packagePaths(in root: URL, entries: [String: FolderComparison.Entry]) throws -> Set<String> {
        var paths: Set<String> = []
        if try root.resourceValues(forKeys: [.isPackageKey]).isPackage == true {
            paths.insert("")
        }
        for (path, entry) in entries where entry.kind == .directory {
            if try entry.url.resourceValues(forKeys: [.isPackageKey]).isPackage == true {
                paths.insert(path)
            }
        }
        return paths
    }

    private static func validatePackagePath(_ path: String, against packages: Set<String>) throws {
        if packages.contains("") { throw FolderOperationError.unsupportedItem(path) }
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + String(component)
            if packages.contains(prefix) { throw FolderOperationError.unsupportedItem(path) }
        }
    }

    private static func validateRoots(_ source: URL, _ destination: URL) throws {
        let a = source.resolvingSymlinksInPath().standardizedFileURL.path
        let b = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard a != b, !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/"),
              (try? FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeDirectory,
              (try? FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw FolderOperationError.invalidRoots
        }
    }

    private static func rootIdentity(_ url: URL) throws -> FolderRootIdentity {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard Darwin.lstat(resolved.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw FolderOperationError.stalePreview("folder root")
        }
        return FolderRootIdentity(
            resolvedPath: resolved.path,
            device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)
        )
    }

    private static func validateSymbolicLink(
        _ entry: FolderComparison.Entry, sourceRoot: URL, destinationRoot: URL, path: String
    ) throws {
        guard entry.kind == .symbolicLink else { return }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)
        guard !target.hasPrefix("/") else { throw FolderOperationError.unsafeSymbolicLink(path) }
        for root in [sourceRoot, destinationRoot] {
            let candidate = root.appendingPathComponent(path).deletingLastPathComponent()
                .appendingPathComponent(target).standardizedFileURL
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            let lexicalRoot = root.standardizedFileURL.path
            let lexical = candidate.path
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard (lexical == lexicalRoot || lexical.hasPrefix(lexicalRoot + "/")),
                  (resolved == rootPath || resolved.hasPrefix(rootPath + "/")) else {
                throw FolderOperationError.unsafeSymbolicLink(path)
            }
        }
    }

    private static func validateDestinationParents(_ root: URL, path: String) throws {
        var current = root
        for component in path.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw FolderOperationError.unsafeDestination(path)
            }
        }
    }

    private static func fingerprintAt(_ url: URL) throws -> FolderFingerprint? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.code == NSFileNoSuchFileError ||
            error.code == NSFileReadNoSuchFileError { return nil }
        let kind: FolderItemKind
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: kind = .file
        case .typeDirectory: kind = .directory
        case .typeSymbolicLink: kind = .symbolicLink
        default: kind = .other
        }
        return try fingerprint(FolderComparison.Entry(url: url, kind: kind,
                                                       size: (attributes[.size] as? NSNumber)?.int64Value ?? 0))
    }

    private static func fingerprint(_ entry: FolderComparison.Entry) throws -> FolderFingerprint {
        switch entry.kind {
        case .directory: return FolderFingerprint(kind: .directory, digest: nil)
        case .symbolicLink:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)
            return FolderFingerprint(kind: .symbolicLink, digest: Array(SHA256.hash(data: Data(target.utf8))))
        case .file:
            let file = try FileHandle(forReadingFrom: entry.url)
            defer { try? file.close() }
            var hasher = SHA256()
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task<Never, Never>.checkCancellation()
                hasher.update(data: bytes)
            }
            return FolderFingerprint(kind: .file, digest: Array(hasher.finalize()))
        case .other: return FolderFingerprint(kind: .other, digest: nil)
        }
    }
}
