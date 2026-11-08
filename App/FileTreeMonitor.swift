import CoreServices
import Darwin
import Foundation

/// FSEvents reports changes anywhere below each watched directory. Consumers
/// rescan their source of truth because events can be coalesced or dropped.
final class FileTreeMonitor: @unchecked Sendable {
    enum MonitorError: LocalizedError {
        case couldNotCreate
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .couldNotCreate: "Could not create a file change monitor."
            case .couldNotStart: "Could not start the file change monitor."
            }
        }
    }

    let events: AsyncStream<[String]>
    private let continuation: AsyncStream<[String]>.Continuation
    private let aliases: [(canonical: String, requested: String)]
    private let queue = DispatchQueue(label: "io.github.michaeldadi.vellograph.file-events")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackInfo: UnsafeMutableRawPointer?

    init(directories: [URL]) throws {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let requested = Array(Set(directories.map { $0.standardizedFileURL.path })).sorted()
        aliases = requested.compactMap { path in
            let canonical = Self.canonicalPath(path)
            return canonical == path ? nil : (canonical: canonical, requested: path)
        }
        let paths = Array(Set(requested.map(Self.canonicalPath))).sorted()
        guard !paths.isEmpty else { throw MonitorError.couldNotCreate }

        // The retained reference is released only after invalidating the stream.
        // This keeps a callback's target alive while FSEvents drains its queue.
        let info = Unmanaged.passRetained(self).toOpaque()
        callbackInfo = info
        var context = FSEventStreamContext(version: 0, info: info, retain: nil,
                                           release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                                            kFSEventStreamCreateFlagFileEvents |
                                            kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, { _, info, _, rawPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileTreeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            monitor.continuation.yield(monitor.projectedPaths((paths as? [String]) ?? []))
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
           0.25, flags) else {
            callbackInfo = nil
            Unmanaged<FileTreeMonitor>.fromOpaque(info).release()
            throw MonitorError.couldNotCreate
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            callbackInfo = nil
            Unmanaged<FileTreeMonitor>.fromOpaque(info).release()
            throw MonitorError.couldNotStart
        }
    }

    func stop() {
        lock.lock()
        let active = stream
        let info = callbackInfo
        stream = nil
        callbackInfo = nil
        lock.unlock()
        guard let active else { return }
        FSEventStreamStop(active)
        FSEventStreamInvalidate(active)
        queue.sync { }
        FSEventStreamRelease(active)
        continuation.finish()
        if let info { Unmanaged<FileTreeMonitor>.fromOpaque(info).release() }
    }

    deinit { stop() }

    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else { return path }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }

    private func projectedPaths(_ paths: [String]) -> [String] {
        var projected = Set(paths)
        for path in paths {
            for alias in aliases {
                if path == alias.canonical {
                    projected.insert(alias.requested)
                } else if path.hasPrefix(alias.canonical + "/") {
                    projected.insert(alias.requested + path.dropFirst(alias.canonical.count))
                }
            }
        }
        return projected.sorted()
    }
}
