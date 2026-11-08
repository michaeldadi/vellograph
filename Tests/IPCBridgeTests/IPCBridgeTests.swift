import Darwin
import Foundation
import IPCBridge
import Testing

@Test func deepLinksParseOnlyExplicitLocalRequests() throws {
    var compare = URLComponents()
    compare.scheme = "vellograph"
    compare.host = "compare"
    compare.queryItems = [URLQueryItem(name: "file", value: "/tmp/a file.txt"),
                          URLQueryItem(name: "file", value: "/tmp/b.txt")]
    #expect(try DeepLinkRequest.parse(compare.url!) ==
            .compare(paths: ["/tmp/a file.txt", "/tmp/b.txt"]))

    var history = URLComponents()
    history.scheme = "vellograph"
    history.host = "history"
    history.queryItems = [URLQueryItem(name: "repo", value: "/tmp/project")]
    #expect(try DeepLinkRequest.parse(history.url!) == .history(repository: "/tmp/project"))

    var changeset = URLComponents()
    changeset.scheme = "vellograph"
    changeset.host = "changeset"
    changeset.queryItems = [URLQueryItem(name: "to", value: "main"),
                            URLQueryItem(name: "repo", value: "/tmp/project"),
                            URLQueryItem(name: "from", value: "HEAD~1")]
    #expect(try DeepLinkRequest.parse(changeset.url!) ==
            .changeset(repository: "/tmp/project", from: "HEAD~1", to: "main"))

    compare.queryItems = [URLQueryItem(name: "file", value: "https://example.com/source")]
    #expect(throws: DeepLinkError.self) { try DeepLinkRequest.parse(compare.url!) }
    compare.queryItems = [URLQueryItem(name: "file", value: "/tmp/a"),
                          URLQueryItem(name: "unexpected", value: "/tmp/b")]
    #expect(throws: DeepLinkError.self) { try DeepLinkRequest.parse(compare.url!) }
    changeset.queryItems = [URLQueryItem(name: "repo", value: "/tmp/project"),
                            URLQueryItem(name: "from", value: "main"),
                            URLQueryItem(name: "from", value: "HEAD")]
    #expect(throws: DeepLinkError.self) { try DeepLinkRequest.parse(changeset.url!) }
}

@Test func privateSocketRoundTripsStructuredRequest() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("vellograph-ipc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("control.sock")
    let server = LocalSocketServer(path: path) { request in
        IPCResponse(status: request.action == .diff && request.paths == ["/tmp/left file", "/tmp/right"]
                    && request.wait ? 0 : 2)
    }
    try server.start()
    defer { server.stop() }
    let request = IPCRequest(action: .diff, paths: ["/tmp/left file", "/tmp/right"], wait: true)
    #expect(try LocalSocketClient.send(request, path: path).status == 0)
}

@Test func stoppingServerPreservesAReplacedSocketPath() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("vellograph-ipc-replaced-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("control.sock")
    let server = LocalSocketServer(path: path) { _ in IPCResponse(status: 0) }
    try server.start()
    try FileManager.default.removeItem(at: path)
    let replacement = Data("keep replacement".utf8)
    try replacement.write(to: path)
    server.stop()
    #expect(try Data(contentsOf: path) == replacement)
}

@Test func insecureSocketDirectoryIsRejected() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("vellograph-ipc-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = LocalSocketServer(path: directory.appendingPathComponent("control.sock")) { _ in
        IPCResponse(status: 0)
    }
    #expect(throws: IPCBridgeError.self) { try server.start() }
    #expect(throws: IPCBridgeError.insecureDirectory) {
        try LocalSocketClient.send(IPCRequest(action: .diff), path: directory.appendingPathComponent("control.sock"))
    }
}

@Test func absentSocketDoesNotLookLikeAnInsecurePeer() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("vellograph-ipc-missing-\(UUID().uuidString)", isDirectory: true)
    let request = IPCRequest(action: .diff)
    #expect(throws: IPCBridgeError.serverUnavailable) {
        try LocalSocketClient.send(request, path: directory.appendingPathComponent("control.sock"))
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: IPCBridgeError.serverUnavailable) {
        try LocalSocketClient.send(request, path: directory.appendingPathComponent("control.sock"))
    }
    try Data("not a socket".utf8).write(to: directory.appendingPathComponent("control.sock"))
    #expect(throws: IPCBridgeError.unsafeSocket) {
        try LocalSocketClient.send(request, path: directory.appendingPathComponent("control.sock"))
    }
}

@Test func silentSocketPeerTimesOut() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("vellograph-ipc-silent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = LocalSocketServer(path: directory.appendingPathComponent("control.sock")) { _ in
        try? await Task.sleep(for: .seconds(1))
        return IPCResponse(status: 0)
    }
    try server.start()
    defer { server.stop() }
    #expect(throws: IPCBridgeError.transport("Response timed out.")) {
        try LocalSocketClient.send(IPCRequest(action: .diff),
                                   path: directory.appendingPathComponent("control.sock"),
                                   responseTimeout: 0.1)
    }
}

@Test func peerClosingBeforeResponseReturnsInvalidMessage() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("vellograph-ipc-disconnect-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("control.sock")
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    defer { Darwin.close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(path.path.utf8CString)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    #expect(pathBytes.count < pathCapacity)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self,
                                  capacity: pathCapacity) { destination in
            for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bound == 0)
    #expect(chmod(path.path, 0o600) == 0)
    #expect(Darwin.listen(fd, 1) == 0)

    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        defer { finished.signal() }
        let peer = Darwin.accept(fd, nil, nil)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        var byte: UInt8 = 0
        while Darwin.read(peer, &byte, 1) == 1 && byte != 10 {}
        // Simulate an app process that exits after receiving the command but
        // before sending a reply.
    }
    #expect(throws: IPCBridgeError.invalidMessage) {
        try LocalSocketClient.send(IPCRequest(action: .diff), path: path,
                                   responseTimeout: 2)
    }
    #expect(finished.wait(timeout: .now() + 3) == .success)
}

@Test func abandonedSnapshotsAreRemovedWithoutTouchingOtherFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellograph-snapshots-\(UUID().uuidString)", isDirectory: true)
    try ManagedSnapshots.prepareDirectory(directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stale = directory.appendingPathComponent("stdin-\(UUID().uuidString).txt")
    let recent = directory.appendingPathComponent("stdin-\(UUID().uuidString).txt")
    let other = directory.appendingPathComponent("notes.txt")
    try Data("old".utf8).write(to: stale)
    try Data("new".utf8).write(to: recent)
    try Data("keep".utf8).write(to: other)
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-7_200)],
                                          ofItemAtPath: stale.path)

    #expect(try ManagedSnapshots.purgeAbandoned(in: directory,
                                                olderThan: .now.addingTimeInterval(-3_600)) == 1)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
}

@Test func clipboardSnapshotIsPrivateAndNotPurgedAsAbandonedStdin() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellograph-clipboard-\(UUID().uuidString)", isDirectory: true)
    try ManagedSnapshots.prepareDirectory(directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let content = Data("clipboard source\n".utf8)
    let file = try ManagedSnapshots.createClipboard(content, fileExtension: "txt", in: directory)
    #expect(ManagedSnapshots.containsClipboard(file, in: directory))
    #expect(!ManagedSnapshots.contains(file, in: directory))
    #expect(try Data(contentsOf: file) == content)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    #expect(try ManagedSnapshots.purgeAbandoned(in: directory,
                                                olderThan: .now.addingTimeInterval(1)) == 0)
    #expect(FileManager.default.fileExists(atPath: file.path))
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-7_200)],
                                          ofItemAtPath: file.path)
    #expect(try ManagedSnapshots.purgeUnusedClipboard(in: directory,
                                                      olderThan: .now.addingTimeInterval(-3_600),
                                                      preserving: [file]) == 0)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(try ManagedSnapshots.purgeUnusedClipboard(in: directory,
                                                      olderThan: .now.addingTimeInterval(-3_600),
                                                      preserving: []) == 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(throws: IPCBridgeError.self) {
        try ManagedSnapshots.createClipboard(content, fileExtension: "../../escape", in: directory)
    }
}
