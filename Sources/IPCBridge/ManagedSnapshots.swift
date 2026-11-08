import Darwin
import Foundation

public enum ManagedSnapshots {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vellograph/Snapshots",
                                    isDirectory: true)
    }

    public static func prepareDirectory(_ directory: URL = ManagedSnapshots.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var details = Darwin.stat()
        guard lstat(directory.path, &details) == 0,
              details.st_uid == geteuid(),
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              details.st_mode & 0o077 == 0 else {
            throw IPCBridgeError.insecureSnapshotDirectory
        }
    }

    public static func contains(_ url: URL, in directory: URL = ManagedSnapshots.directory) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("stdin-"), name.hasSuffix(".txt"),
              UUID(uuidString: String(name.dropFirst(6).dropLast(4))) != nil else { return false }
        return url.standardizedFileURL.deletingLastPathComponent().path ==
            directory.standardizedFileURL.path
    }

    public static func containsClipboard(_ url: URL,
                                         in directory: URL = ManagedSnapshots.directory) -> Bool {
        let name = url.lastPathComponent
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].hasPrefix("clipboard-"),
              UUID(uuidString: String(components[0].dropFirst("clipboard-".count))) != nil,
              ["txt", "png", "tiff"].contains(String(components[1])) else { return false }
        return url.standardizedFileURL.deletingLastPathComponent().path ==
            directory.standardizedFileURL.path
    }

    /// Creates a private, durable shelf snapshot of clipboard content.
    public static func createClipboard(_ data: Data, fileExtension: String,
                                       in directory: URL = ManagedSnapshots.directory) throws -> URL {
        guard ["txt", "png", "tiff"].contains(fileExtension), data.count <= 100_000_000 else {
            throw IPCBridgeError.invalidClipboardSnapshot
        }
        try prepareDirectory(directory)
        let url = directory.appendingPathComponent("clipboard-\(UUID().uuidString).\(fileExtension)")
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw IPCBridgeError.invalidClipboardSnapshot }
        var completed = false
        defer {
            Darwin.close(fd)
            if !completed { unlink(url.path) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw IPCBridgeError.invalidClipboardSnapshot
                }
                guard count > 0 else { throw IPCBridgeError.invalidClipboardSnapshot }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw IPCBridgeError.invalidClipboardSnapshot }
        completed = true
        return url
    }

    /// Removes only old, regular files with Vellograph's generated names.
    /// Fresh snapshots may belong to a CLI request that is launching the app.
    @discardableResult
    public static func purgeAbandoned(in directory: URL = ManagedSnapshots.directory,
                                      olderThan cutoff: Date) throws -> Int {
        try purge(in: directory, olderThan: cutoff, preserving: [], matching: contains)
    }

    /// Cleans up clipboard captures left by a crash or interrupted save while
    /// preserving the sources in the current shelf and restored tabs.
    @discardableResult
    public static func purgeUnusedClipboard(in directory: URL = ManagedSnapshots.directory,
                                            olderThan cutoff: Date,
                                            preserving urls: [URL]) throws -> Int {
        try purge(in: directory, olderThan: cutoff,
                  preserving: Set(urls.map { $0.standardizedFileURL.path }),
                  matching: containsClipboard)
    }

    private static func purge(in directory: URL, olderThan cutoff: Date,
                              preserving paths: Set<String>,
                              matching: (URL, URL) -> Bool) throws -> Int {
        try prepareDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
        var removed = 0
        for file in files where matching(file, directory) &&
            !paths.contains(file.standardizedFileURL.path) {
            var details = Darwin.stat()
            guard lstat(file.path, &details) == 0,
                  details.st_uid == geteuid(),
                  details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  details.st_nlink == 1,
                  Date(timeIntervalSince1970: TimeInterval(details.st_mtimespec.tv_sec)) < cutoff else {
                continue
            }
            if unlink(file.path) == 0 { removed += 1 }
        }
        return removed
    }
}
