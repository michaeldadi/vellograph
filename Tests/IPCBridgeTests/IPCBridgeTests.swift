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
