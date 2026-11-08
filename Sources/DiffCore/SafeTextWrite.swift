import Darwin
import Foundation

public enum SafeTextWriteError: Error, LocalizedError {
    case destinationChanged
    case notRegularFile
    case coordinationFailed

    public var errorDescription: String? {
        switch self {
        case .destinationChanged: "The destination changed since it was opened. Reopen it before replacing it."
        case .notRegularFile: "The destination must be a regular file, not a symbolic link or folder."
        case .coordinationFailed: "The destination could not be safely coordinated for writing."
        }
    }
}

public struct TextWriteResult: Sendable {
    public let recoveryURL: URL?

    public init(recoveryURL: URL?) {
        self.recoveryURL = recoveryURL
    }
}

public enum SafeTextWrite {
    /// Creates a new file without replacing anything that appeared after the
    /// merge began. The temporary file is on the destination volume and is
    /// linked into place only after its bytes are durable.
    public static func create(at destination: URL, data: Data) throws {
        let destination = destination.standardizedFileURL
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".vellograph-write-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { unlink(temporary.path) }
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var sent = 0
                while sent < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: sent), buffer.count - sent)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(.init(rawValue: errno) ?? .EIO)
                    }
                    sent += count
                }
            }
            guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            Darwin.close(fd)
            throw error
        }
        Darwin.close(fd)
        guard link(temporary.path, destination.path) == 0 else {
            if errno == EEXIST { throw SafeTextWriteError.destinationChanged }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    /// Coordinates a replacement, checks the original bytes again inside the
    /// write accessor, and retains a sibling recovery copy before atomic write.
    public static func replace(at destination: URL, expected: Data, with newData: Data) throws -> TextWriteResult {
        let destination = destination.standardizedFileURL
        var coordinationError: NSError?
        var operationError: Error?
        var result: TextWriteResult?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing,
                                       error: &coordinationError) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw SafeTextWriteError.notRegularFile
                }
                let current = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                guard current == expected else { throw SafeTextWriteError.destinationChanged }
                if current == newData {
                    result = TextWriteResult(recoveryURL: nil)
                    return
                }
                let recovery = destination.deletingLastPathComponent()
                    .appendingPathComponent(".vellograph-recovery-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
                let saved = recovery.appendingPathComponent(destination.lastPathComponent)
                try current.write(to: saved, options: .atomic)
                try newData.write(to: coordinatedURL, options: .atomic)
                result = TextWriteResult(recoveryURL: saved)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw SafeTextWriteError.coordinationFailed }
        return result ?? TextWriteResult(recoveryURL: nil)
    }

    /// Removes a file only if its bytes still match the open conflict, keeping
    /// a sibling recovery copy. A missing file is a no-op only when it was
    /// already missing when the conflict was opened.
    public static func delete(at destination: URL, expected: Data?) throws -> TextWriteResult {
        let destination = destination.standardizedFileURL
        guard let expected else {
            var metadata = stat()
            if lstat(destination.path, &metadata) == 0 { throw SafeTextWriteError.destinationChanged }
            guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return TextWriteResult(recoveryURL: nil)
        }
        var coordinationError: NSError?
        var operationError: Error?
        var result: TextWriteResult?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forDeleting,
                                       error: &coordinationError) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw SafeTextWriteError.notRegularFile
                }
                let current = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                guard current == expected else { throw SafeTextWriteError.destinationChanged }
                let recovery = destination.deletingLastPathComponent()
                    .appendingPathComponent(".vellograph-recovery-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
                let saved = recovery.appendingPathComponent(destination.lastPathComponent)
                try current.write(to: saved, options: .atomic)
                try FileManager.default.removeItem(at: coordinatedURL)
                result = TextWriteResult(recoveryURL: saved)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw SafeTextWriteError.coordinationFailed }
        return result ?? TextWriteResult(recoveryURL: nil)
    }
}
