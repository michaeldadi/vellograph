import Darwin
import Foundation

public final class LocalSocketServer: @unchecked Sendable {
    private let path: URL
    private let handler: @Sendable (IPCRequest) async -> IPCResponse
    private let lock = NSLock()
    private var listener: Int32 = -1

    public init(path: URL = IPCPaths.socket,
                handler: @escaping @Sendable (IPCRequest) async -> IPCResponse) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try SocketIO.ensurePrivateDirectory(path.deletingLastPathComponent())
        let address = try SocketIO.address(for: path)
        try SocketIO.removeStaleSocket(at: path, address: address)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketIO.systemError() }
        do {
            try SocketIO.disableSIGPIPE(fd)
            try SocketIO.withAddress(address) { pointer, length in
                guard Darwin.bind(fd, pointer, length) == 0 else { throw SocketIO.systemError() }
            }
            guard chmod(path.path, 0o600) == 0 else { throw SocketIO.systemError() }
            guard Darwin.listen(fd, 16) == 0 else { throw SocketIO.systemError() }
            lock.lock()
            guard listener < 0 else {
                lock.unlock()
                throw IPCBridgeError.alreadyRunning
            }
            listener = fd
            lock.unlock()
        } catch {
            Darwin.close(fd)
            unlink(path.path)
            throw error
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        unlink(path.path)
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { break }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                handleClient(client)
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { Darwin.close(client) }
        do {
            try SocketIO.disableSIGPIPE(client)
            try SocketIO.verifyPeer(client)
            let data = try SocketIO.readLine(client, limit: 1_048_576)
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)
            guard request.version == 1 else { throw IPCBridgeError.invalidMessage }

            let box = ResponseBox()
            let ready = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task {
                box.set(await handler(request))
                ready.signal()
            }
            ready.wait()
            let response = box.get() ?? IPCResponse(status: 2, message: "No application response.")
            try SocketIO.writeLine(client, value: response)
        } catch {
            try? SocketIO.writeLine(client, value: IPCResponse(status: 2,
                                                                 message: error.localizedDescription))
        }
    }
}

public enum LocalSocketClient {
    public static func send(_ request: IPCRequest, path: URL = IPCPaths.socket) throws -> IPCResponse {
        try SocketIO.ensurePrivateDirectory(path.deletingLastPathComponent(), create: false)
        let address = try SocketIO.address(for: path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketIO.systemError() }
        defer { Darwin.close(fd) }
        try SocketIO.disableSIGPIPE(fd)
        try SocketIO.withAddress(address) { pointer, length in
            guard Darwin.connect(fd, pointer, length) == 0 else { throw SocketIO.systemError() }
        }
        try SocketIO.verifyPeer(fd)
        try SocketIO.writeLine(fd, value: request)
        let data = try SocketIO.readLine(fd, limit: 65_536)
        return try JSONDecoder().decode(IPCResponse.self, from: data)
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: IPCResponse?

    func set(_ value: IPCResponse) {
        lock.lock(); response = value; lock.unlock()
    }

    func get() -> IPCResponse? {
        lock.lock(); defer { lock.unlock() }
        return response
    }
}

private enum SocketIO {
    static func systemError() -> IPCBridgeError {
        .transport(String(cString: strerror(errno)))
    }

    static func ensurePrivateDirectory(_ url: URL, create: Bool = true) throws {
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var details = Darwin.stat()
        guard lstat(url.path, &details) == 0,
              details.st_uid == geteuid(),
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              details.st_mode & 0o077 == 0 else {
            throw IPCBridgeError.insecureDirectory
        }
    }

    static func address(for url: URL) throws -> sockaddr_un {
        let bytes = Array(url.path.utf8CString)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw IPCBridgeError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = byte }
            }
        }
        return address
    }

    static func withAddress<T>(_ address: sockaddr_un,
                               _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        var address = address
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                try body(socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func removeStaleSocket(at url: URL, address: sockaddr_un) throws {
        var details = Darwin.stat()
        guard lstat(url.path, &details) == 0 else {
            if errno == ENOENT { return }
            throw systemError()
        }
        guard details.st_uid == geteuid(), details.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw IPCBridgeError.insecureDirectory
        }
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw systemError() }
        let connected = withAddress(address) { pointer, length in
            Darwin.connect(probe, pointer, length) == 0
        }
        Darwin.close(probe)
        if connected { throw IPCBridgeError.alreadyRunning }
        guard unlink(url.path) == 0 else { throw systemError() }
    }

    static func disableSIGPIPE(_ fd: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw systemError() }
    }

    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { throw systemError() }
        guard uid == geteuid() else { throw IPCBridgeError.wrongPeer }
    }

    static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < limit {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError()
            }
            if count == 0 { throw IPCBridgeError.invalidMessage }
            if byte == 10 { return result }
            result.append(byte)
        }
        throw IPCBridgeError.messageTooLarge
    }

    static func writeLine<T: Encodable>(_ fd: Int32, value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), buffer.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError()
                }
                sent += count
            }
        }
    }
}
