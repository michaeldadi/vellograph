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
    let sourceIdentity: FolderEntryIdentity?
    let sourceParentIdentity: FolderEntryIdentity?
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

struct FolderEntryIdentity: Sendable, Equatable {
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
        let source = source.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        try validateRoots(source, destination)
        let sourceIdentity = try rootIdentity(source)
        let destinationIdentity = try rootIdentity(destination)
        let sourceHandle = try FolderDirectoryHandle(
            url: URL(fileURLWithPath: sourceIdentity.resolvedPath, isDirectory: true))
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
            let (sourceParent, sourceName) = try sourceParent(in: sourceHandle, for: path)
            guard let sourceEntryIdentity = try sourceParent.entryIdentity(sourceName) else {
                throw FolderOperationError.stalePreview(path)
            }
            let sourceParentIdentity = try sourceParent.directoryIdentity()
            let destinationFingerprint = try destinationEntry.map(fingerprint)
            if let destinationEntry, destinationEntry.kind != sourceEntry.kind {
                throw FolderOperationError.unsupportedItem(path)
            }
            if sourceEntry.kind == .directory {
                if destinationEntry == nil {
                    actions.append(FolderAction(path: path, kind: .createDirectory,
                                                itemKind: .directory,
                                                sourceFingerprint: sourceFingerprint,
                                                destinationFingerprint: nil,
                                                sourceIdentity: sourceEntryIdentity,
                                                sourceParentIdentity: sourceParentIdentity))
                }
            } else if destinationEntry == nil {
                actions.append(FolderAction(path: path, kind: .create,
                                            itemKind: sourceEntry.kind,
                                            sourceFingerprint: sourceFingerprint,
                                            destinationFingerprint: nil,
                                            sourceIdentity: sourceEntryIdentity,
                                            sourceParentIdentity: sourceParentIdentity))
            } else if sourceFingerprint != destinationFingerprint {
                actions.append(FolderAction(path: path, kind: .replace,
                                            itemKind: sourceEntry.kind,
                                            sourceFingerprint: sourceFingerprint,
                                            destinationFingerprint: destinationFingerprint,
                                            sourceIdentity: sourceEntryIdentity,
                                            sourceParentIdentity: sourceParentIdentity))
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
                                            destinationFingerprint: try fingerprint(entry),
                                            sourceIdentity: nil, sourceParentIdentity: nil))
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
    func apply(afterFinalTargetCheck: ((FolderAction) throws -> Void)?,
               afterDestinationOpen: ((FolderAction) throws -> Void)? = nil,
               afterSourcePreflight: ((FolderAction) throws -> Void)? = nil) throws -> FolderApplyResult {
        try preflight()
        guard !actions.isEmpty else { return FolderApplyResult(appliedCount: 0, recoveryFolder: nil) }
        let fm = FileManager.default
        let destinationHandle = try FolderDirectoryHandle(
            url: URL(fileURLWithPath: destinationIdentity.resolvedPath, isDirectory: true))
        let sourceHandle = try FolderDirectoryHandle(
            url: URL(fileURLWithPath: sourceIdentity.resolvedPath, isDirectory: true))
        guard destinationHandle.identityMatches(destinationIdentity) else {
            throw FolderOperationError.stalePreview("folder root")
        }
        guard sourceHandle.identityMatches(sourceIdentity) else {
            throw FolderOperationError.stalePreview("folder root")
        }
        let identifier = UUID().uuidString
        // A selected root may be an alias on another volume. Keep staging and
        // recovery beside the resolved destination so exclusive renames stay
        // on the same filesystem as the pinned destination directory.
        let parent = URL(fileURLWithPath: destinationIdentity.resolvedPath,
                         isDirectory: true).deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".vellograph-stage-\(identifier)", isDirectory: true)
        let recovery = parent.appendingPathComponent(".vellograph-recovery-\(identifier)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let stageHandle = try FolderDirectoryHandle(url: stage)

        // Copy every source item before touching the destination. A failed
        // source read therefore leaves destination contents unchanged.
        for action in actions where action.kind == .create || action.kind == .replace {
            try afterSourcePreflight?(action)
            try validateSourceIdentity(action, using: sourceHandle)
            let (sourceParent, sourceName) = try Self.sourceParent(in: sourceHandle, for: action.path)
            guard try sourceParent.fingerprint(sourceName) == action.sourceFingerprint else {
                throw FolderOperationError.stalePreview(action.path)
            }
            let (stageParent, stageName) = try stageHandle.parent(for: action.path, creating: true)
            try sourceParent.copy(sourceName, to: stageParent, as: stageName,
                                  kind: action.itemKind, expectedIdentity: action.sourceIdentity)
            guard try stageParent.fingerprint(stageName) == action.sourceFingerprint else {
                throw FolderOperationError.stalePreview(action.path)
            }
            let (currentSourceParent, _) = try Self.sourceParent(in: sourceHandle, for: action.path)
            guard currentSourceParent.sameDirectory(as: sourceParent) else {
                throw FolderOperationError.stalePreview(action.path)
            }
        }
        try preflight()
        try fm.createDirectory(at: recovery, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let recoveryHandle = try FolderDirectoryHandle(url: recovery)
        struct Applied {
            let backup: URL?
            let targetParent: FolderDirectoryHandle
            let backupParent: FolderDirectoryHandle?
            let name: String
            let restoreDirectory: Bool
            let createdDirectory: Bool
            let restorePermissions: mode_t?
            var installedFingerprint: FolderFingerprint?
            var installedIdentity: FolderEntryIdentity?
        }
        var applied: [Applied] = []
        do {
            for action in actions {
                try Task<Never, Never>.checkCancellation()
                try validateRootIdentities()
                try validateSourceIdentity(action, using: sourceHandle)
                try Self.validateDestinationParents(destinationRoot, path: action.path)
                if action.itemKind == .symbolicLink && action.kind != .remove {
                    try Self.validateSymbolicLink(
                        FolderComparison.Entry(url: sourceRoot.appendingPathComponent(action.path),
                                               kind: .symbolicLink, size: 0),
                        sourceRoot: sourceRoot, destinationRoot: destinationRoot,
                        path: action.path)
                }
                let (initialParent, name) = try destinationHandle.parent(for: action.path)
                guard try initialParent.fingerprint(name) == action.destinationFingerprint else {
                    throw FolderOperationError.stalePreview(action.path)
                }
                try afterFinalTargetCheck?(action)
                try validateRootIdentities()
                try Self.validateDestinationParents(destinationRoot, path: action.path)
                let (targetParent, targetName) = try destinationHandle.parent(for: action.path)
                guard try targetParent.fingerprint(targetName) == action.destinationFingerprint else {
                    throw FolderOperationError.stalePreview(action.path)
                }
                let originalIdentity = try targetParent.entryIdentity(targetName)
                try afterDestinationOpen?(action)
                if action.kind == .remove, action.itemKind == .directory {
                    // rmdir is atomic and fails if an excluded or newly arrived
                    // child exists. Moving the whole directory would silently
                    // remove such a child from the user's visible scope.
                    let permissions = try targetParent.permissions(targetName)
                    do { try targetParent.remove(targetName, directory: true) }
                    catch { throw FolderOperationError.stalePreview(action.path) }
                    applied.append(Applied(backup: nil,
                                           targetParent: targetParent, backupParent: nil, name: targetName,
                                           restoreDirectory: true, createdDirectory: false,
                                           restorePermissions: permissions, installedFingerprint: nil,
                                           installedIdentity: nil))
                    let (currentParent, _) = try destinationHandle.parent(for: action.path)
                    guard currentParent.sameDirectory(as: targetParent) else {
                        throw FolderOperationError.stalePreview(action.path)
                    }
                    try validateRootIdentities()
                    continue
                }
                let backup: URL?
                let backupParent: FolderDirectoryHandle?
                if action.destinationFingerprint != nil {
                    let saved = recovery.appendingPathComponent(action.path)
                    let (parent, backupName) = try recoveryHandle.parent(for: action.path, creating: true)
                    try targetParent.move(targetName, to: parent, as: backupName)
                    backup = saved
                    backupParent = parent
                } else {
                    backup = nil
                    backupParent = nil
                }
                applied.append(Applied(backup: backup,
                                       targetParent: targetParent, backupParent: backupParent,
                                       name: targetName,
                                       restoreDirectory: false,
                                       createdDirectory: action.kind == .createDirectory,
                                       restorePermissions: nil, installedFingerprint: nil,
                                       installedIdentity: nil))
                if let backupParent,
                   (try backupParent.fingerprint(targetName) != action.destinationFingerprint ||
                    backupParent.entryIdentity(targetName) != originalIdentity) {
                    throw FolderOperationError.stalePreview(action.path)
                }
                switch action.kind {
                case .createDirectory:
                    do { try targetParent.makeDirectory(targetName) }
                    catch let error as POSIXError where error.code == .EEXIST {
                        throw FolderOperationError.stalePreview(action.path)
                    }
                case .create, .replace:
                    let (sourceParent, sourceName) = try stageHandle.parent(for: action.path)
                    do { try sourceParent.move(sourceName, to: targetParent, as: targetName) }
                    catch let error as POSIXError where error.code == .EEXIST {
                        throw FolderOperationError.stalePreview(action.path)
                    }
                case .remove: break
                }
                applied[applied.count - 1].installedFingerprint = action.kind == .remove
                    ? nil : action.sourceFingerprint
                applied[applied.count - 1].installedIdentity = try targetParent.entryIdentity(targetName)
                let (currentParent, _) = try destinationHandle.parent(for: action.path)
                guard currentParent.sameDirectory(as: targetParent) else {
                    throw FolderOperationError.stalePreview(action.path)
                }
                try validateRootIdentities()
            }
        } catch {
            var rollbackFailed = false
            for operation in applied.reversed() {
                do {
                    let current = try operation.targetParent.fingerprint(operation.name)
                    if operation.installedFingerprint == nil,
                       operation.backup == nil, !operation.restoreDirectory, current != nil {
                        // A new external item arrived before our exclusive
                        // create. No part of this action touched that item.
                        continue
                    }
                    guard current == operation.installedFingerprint else {
                        throw FolderOperationError.rollbackFailed(recovery.path)
                    }
                    if current != nil,
                       try operation.targetParent.entryIdentity(operation.name) != operation.installedIdentity {
                        throw FolderOperationError.rollbackFailed(recovery.path)
                    }
                    if current != nil {
                        try operation.targetParent.remove(operation.name,
                                                          directory: operation.createdDirectory)
                    }
                    if operation.restoreDirectory {
                        try operation.targetParent.makeDirectory(operation.name,
                                                                 permissions: operation.restorePermissions ?? 0o777)
                        if let permissions = operation.restorePermissions {
                            try operation.targetParent.setPermissions(permissions,
                                                                      for: operation.name)
                        }
                    }
                    if let backupParent = operation.backupParent {
                        try backupParent.move(operation.name, to: operation.targetParent)
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
        let sourceHandle = try FolderDirectoryHandle(
            url: URL(fileURLWithPath: sourceIdentity.resolvedPath, isDirectory: true))
        guard sourceHandle.identityMatches(sourceIdentity) else {
            throw FolderOperationError.stalePreview("folder root")
        }
        let packages = try Self.packagePaths(in: sourceRoot, entries: currentSource)
            .union(Self.packagePaths(in: destinationRoot, entries: currentDestination))
        guard Set(currentSource.keys) == sourcePaths, Set(currentDestination.keys) == destinationPaths else {
            throw FolderOperationError.stalePreview("folder contents")
        }
        for action in actions {
            try validateSourceIdentity(action, using: sourceHandle)
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

    private func validateSourceIdentity(_ action: FolderAction,
                                        using sourceHandle: FolderDirectoryHandle) throws {
        guard action.sourceIdentity != nil else { return }
        let (parent, name) = try Self.sourceParent(in: sourceHandle, for: action.path)
        guard try parent.directoryIdentity() == action.sourceParentIdentity,
              try parent.entryIdentity(name) == action.sourceIdentity else {
            throw FolderOperationError.stalePreview(action.path)
        }
    }

    private static func sourceParent(in root: FolderDirectoryHandle,
                                     for path: String) throws -> (FolderDirectoryHandle, String) {
        do { return try root.parent(for: path) }
        catch FolderOperationError.unsafeDestination {
            throw FolderOperationError.stalePreview(path)
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
              (try? FileManager.default.attributesOfItem(atPath: a)[.type] as? FileAttributeType) == .typeDirectory,
              (try? FileManager.default.attributesOfItem(atPath: b)[.type] as? FileAttributeType) == .typeDirectory else {
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

private final class FolderDirectoryHandle {
    let fd: Int32

    init(url: URL) throws {
        fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.systemError() }
    }

    private init(fd: Int32) { self.fd = fd }

    deinit { Darwin.close(fd) }

    func identityMatches(_ identity: FolderRootIdentity) -> Bool {
        var details = stat()
        return fstat(fd, &details) == 0 &&
            UInt64(details.st_dev) == identity.device && UInt64(details.st_ino) == identity.inode
    }

    func sameDirectory(as other: FolderDirectoryHandle) -> Bool {
        var left = stat()
        var right = stat()
        return fstat(fd, &left) == 0 && fstat(other.fd, &right) == 0 &&
            left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    func directoryIdentity() throws -> FolderEntryIdentity {
        var details = stat()
        guard fstat(fd, &details) == 0 else { throw Self.systemError() }
        return FolderEntryIdentity(device: UInt64(details.st_dev), inode: UInt64(details.st_ino))
    }

    func parent(for path: String, creating: Bool = false) throws -> (FolderDirectoryHandle, String) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FolderOperationError.unsafeDestination(path)
        }
        let copy = dup(fd)
        guard copy >= 0 else { throw Self.systemError() }
        var current = FolderDirectoryHandle(fd: copy)
        for part in parts.dropLast() {
            if creating && mkdirat(current.fd, part, 0o700) != 0 && errno != EEXIST {
                throw Self.systemError()
            }
            let next = openat(current.fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw FolderOperationError.unsafeDestination(path) }
            current = FolderDirectoryHandle(fd: next)
        }
        return (current, parts[parts.count - 1])
    }

    func fingerprint(_ name: String) throws -> FolderFingerprint? {
        var details = stat()
        guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.systemError()
        }
        switch details.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            return FolderFingerprint(kind: .directory, digest: nil)
        case mode_t(S_IFLNK):
            var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
            let count = bytes.withUnsafeMutableBytes { buffer in
                readlinkat(fd, name, buffer.baseAddress, buffer.count)
            }
            guard count >= 0, count < bytes.count else { throw Self.systemError() }
            return FolderFingerprint(kind: .symbolicLink,
                                     digest: Array(SHA256.hash(data: Data(bytes.prefix(count)))))
        case mode_t(S_IFREG):
            let fileFD = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fileFD >= 0 else { throw Self.systemError() }
            let file = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
            defer { try? file.close() }
            var opened = stat()
            guard fstat(fileFD, &opened) == 0,
                  opened.st_dev == details.st_dev, opened.st_ino == details.st_ino else {
                throw FolderOperationError.stalePreview(name)
            }
            var hasher = SHA256()
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task<Never, Never>.checkCancellation()
                hasher.update(data: chunk)
            }
            return FolderFingerprint(kind: .file, digest: Array(hasher.finalize()))
        default:
            return FolderFingerprint(kind: .other, digest: nil)
        }
    }

    func entryIdentity(_ name: String) throws -> FolderEntryIdentity? {
        var details = stat()
        guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.systemError()
        }
        return FolderEntryIdentity(device: UInt64(details.st_dev), inode: UInt64(details.st_ino))
    }

    func copy(_ name: String, to destination: FolderDirectoryHandle,
              as destinationName: String, kind: FolderItemKind,
              expectedIdentity: FolderEntryIdentity?) throws {
        switch kind {
        case .file:
            let sourceFD = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw FolderOperationError.stalePreview(name) }
            defer { Darwin.close(sourceFD) }
            var details = stat()
            guard fstat(sourceFD, &details) == 0,
                  details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  FolderEntryIdentity(device: UInt64(details.st_dev), inode: UInt64(details.st_ino))
                      == expectedIdentity else {
                throw FolderOperationError.stalePreview(name)
            }
            let destinationFD = openat(destination.fd, destinationName,
                                       O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destinationFD >= 0 else { throw Self.systemError() }
            defer { Darwin.close(destinationFD) }
            guard fcopyfile(sourceFD, destinationFD, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw Self.systemError()
            }
        case .symbolicLink:
            guard try entryIdentity(name) == expectedIdentity else {
                throw FolderOperationError.stalePreview(name)
            }
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = target.withUnsafeMutableBufferPointer { buffer in
                readlinkat(fd, name, buffer.baseAddress, buffer.count - 1)
            }
            guard count >= 0, count < target.count - 1 else {
                throw FolderOperationError.stalePreview(name)
            }
            guard try entryIdentity(name) == expectedIdentity else {
                throw FolderOperationError.stalePreview(name)
            }
            guard target.withUnsafeBufferPointer({ buffer in
                symlinkat(buffer.baseAddress, destination.fd, destinationName)
            }) == 0 else { throw Self.systemError() }
        case .directory, .other:
            throw FolderOperationError.unsupportedItem(name)
        }
    }

    func move(_ name: String, to destination: FolderDirectoryHandle, as destinationName: String? = nil) throws {
        guard renameatx_np(fd, name, destination.fd, destinationName ?? name,
                           UInt32(RENAME_EXCL)) == 0 else {
            throw Self.systemError()
        }
    }

    func permissions(_ name: String) throws -> mode_t {
        var details = stat()
        guard fstatat(fd, name, &details, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.systemError()
        }
        return details.st_mode & 0o7777
    }

    func makeDirectory(_ name: String, permissions: mode_t = 0o777) throws {
        guard mkdirat(fd, name, permissions) == 0 else { throw Self.systemError() }
    }

    func remove(_ name: String, directory: Bool) throws {
        guard unlinkat(fd, name, directory ? AT_REMOVEDIR : 0) == 0 else {
            throw Self.systemError()
        }
    }

    func setPermissions(_ permissions: mode_t, for name: String) throws {
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw Self.systemError() }
        defer { Darwin.close(child) }
        guard fchmod(child, permissions) == 0 else { throw Self.systemError() }
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
