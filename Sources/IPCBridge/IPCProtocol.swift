import Foundation

public enum IPCAction: String, Codable, Sendable {
    case diff
    case merge
    case changeset
    case workingCopy
}

public struct IPCRequest: Codable, Sendable {
    public let version: Int
    public let action: IPCAction
    public let paths: [String]
    public let wait: Bool
    public let label: String?
    public let repository: String?
    public let fromRef: String?
    public let toRef: String?
    public let output: String?

    public init(action: IPCAction, paths: [String] = [], wait: Bool = false,
                label: String? = nil, repository: String? = nil,
                fromRef: String? = nil, toRef: String? = nil, output: String? = nil) {
        version = 1
        self.action = action
        self.paths = paths
        self.wait = wait
        self.label = label
        self.repository = repository
        self.fromRef = fromRef
        self.toRef = toRef
        self.output = output
    }
}

public struct IPCResponse: Codable, Sendable {
    public let status: Int32
    public let message: String?

    public init(status: Int32, message: String? = nil) {
        self.status = status
        self.message = message
    }
}

public enum IPCBridgeError: Error, LocalizedError, Equatable {
    case serverUnavailable
    case insecureDirectory
    case unsafeSocket
    case insecureSnapshotDirectory
    case pathTooLong
    case alreadyRunning
    case transport(String)
    case wrongPeer
    case messageTooLarge
    case invalidMessage
    case invalidClipboardSnapshot

    public var errorDescription: String? {
        switch self {
        case .serverUnavailable: "Vellograph is not accepting local commands yet."
        case .insecureDirectory: "The Vellograph IPC directory is not a private directory owned by this user."
        case .unsafeSocket: "The Vellograph IPC socket is not a private socket owned by this user."
        case .insecureSnapshotDirectory: "The Vellograph snapshot directory is not a private directory owned by this user."
        case .pathTooLong: "The Vellograph IPC socket path is too long."
        case .alreadyRunning: "A Vellograph IPC server is already running."
        case .transport(let message): "Vellograph IPC failed: \(message)"
        case .wrongPeer: "The Vellograph IPC peer belongs to another user."
        case .messageTooLarge: "The Vellograph IPC message is too large."
        case .invalidMessage: "The Vellograph IPC message is invalid."
        case .invalidClipboardSnapshot: "The clipboard content could not be saved privately (100 MB maximum)."
        }
    }
}

public enum IPCPaths {
    public static var socket: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vellograph/IPC", isDirectory: true)
            .appendingPathComponent("control.sock")
    }
}
