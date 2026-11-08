import CryptoKit
import Darwin
import Foundation

public enum GitToolConfigurationError: Error, LocalizedError {
    case invalidExecutable
    case unsafeConfigurationPath
    case alreadyInstalled
    case notInstalled
    case configurationChanged
    case backupInvalid
    case rollbackFailed
    case gitFailed

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable: "Choose an installed vellograph executable before configuring Git."
        case .unsafeConfigurationPath: "The Git configuration or backup path is unsafe."
        case .alreadyInstalled: "A Vellograph Git tool backup already exists. Uninstall it before installing again."
        case .notInstalled: "No Vellograph Git tool backup exists for this configuration."
        case .configurationChanged: "Git tool settings changed after Vellograph installed them. Review them manually before restoring."
        case .backupInvalid: "The Vellograph Git tool backup could not be read safely."
        case .rollbackFailed: "Git tool setup failed and the original settings could not be fully restored. Use the backup to recover them."
        case .gitFailed: "Git could not update this configuration."
        }
    }
}

public struct GitToolChange: Sendable {
    public let key: String
    public let newValue: String
    public let replacesExistingValue: Bool
}

public struct GitToolConfiguration: Sendable {
    public let configFile: URL
    public let backupFile: URL
    public let cliExecutable: URL

    private static let keys = [
        "diff.tool",
        "difftool.vellograph.cmd",
        "merge.tool",
        "mergetool.vellograph.cmd",
        "mergetool.vellograph.trustExitCode",
    ]

    private struct Backup: Codable {
        let configurationPath: String
        let previous: [String: [String]]
        let installed: [String: String]
    }

    public init(configFile: URL, backupDirectory: URL, cliExecutable: URL) {
        self.configFile = configFile.standardizedFileURL
        self.cliExecutable = cliExecutable.standardizedFileURL
        let digest = SHA256.hash(data: Data(self.configFile.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.backupFile = backupDirectory.standardizedFileURL
            .appendingPathComponent("git-tools-\(digest).json")
    }

    public static func globalConfigurationFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gitconfig")
    }

    public static func repositoryConfigurationFile(_ repository: URL) throws -> URL {
        let git = GitClient()
        let root = try git.repository(at: repository).root
        let data = try git.run(in: root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else { throw GitToolConfigurationError.unsafeConfigurationPath }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("config")
    }

    public func preview() throws -> [GitToolChange] {
        try validatePaths()
        return try Self.keys.map { key in
            GitToolChange(key: key, newValue: desired[key]!,
                          replacesExistingValue: try !values(for: key).isEmpty)
        }
    }

    public func install() throws {
        try validatePaths(createBackupDirectory: true)
        if FileManager.default.fileExists(atPath: backupFile.path) {
            let backup = try readBackup()
            if try Self.keys.allSatisfy({ try values(for: $0) == [backup.installed[$0]!] }) { return }
            throw GitToolConfigurationError.alreadyInstalled
        }
        var previous: [String: [String]] = [:]
        for key in Self.keys { previous[key] = try values(for: key) }
        let backup = Backup(configurationPath: configFile.path, previous: previous,
                            installed: desired)
        try writeBackup(backup)
        do {
            for key in Self.keys { try setValues([desired[key]!], for: key) }
        } catch {
            do {
                try restore(backup)
                try FileManager.default.removeItem(at: backupFile)
            } catch {
                throw GitToolConfigurationError.rollbackFailed
            }
            throw error
        }
    }

    public func uninstall() throws {
        try validatePaths(requireExecutable: false)
        guard FileManager.default.fileExists(atPath: backupFile.path) else {
            throw GitToolConfigurationError.notInstalled
        }
        let backup = try readBackup()
        try restore(backup)
        try FileManager.default.removeItem(at: backupFile)
    }

    private var desired: [String: String] {
        let command = shellQuoted(cliExecutable.path)
        return [
            "diff.tool": "vellograph",
            "difftool.vellograph.cmd": "\(command) diff --wait -- \"$LOCAL\" \"$REMOTE\"",
            "merge.tool": "vellograph",
            "mergetool.vellograph.cmd": "\(command) merge --base \"$BASE\" --output \"$MERGED\" -- \"$LOCAL\" \"$REMOTE\"",
            "mergetool.vellograph.trustExitCode": "true",
        ]
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func validatePaths(createBackupDirectory: Bool = false,
                               requireExecutable: Bool = true) throws {
        if requireExecutable {
            let resolved = cliExecutable.resolvingSymlinksInPath()
            let executableValues = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard executableValues?.isRegularFile == true,
                  FileManager.default.isExecutableFile(atPath: cliExecutable.path) else {
                throw GitToolConfigurationError.invalidExecutable
            }
        }
        let configValues = try? configFile.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard configValues?.isSymbolicLink != true, configValues?.isDirectory != true else {
            throw GitToolConfigurationError.unsafeConfigurationPath
        }
        let backupDirectory = backupFile.deletingLastPathComponent()
        if createBackupDirectory {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        if FileManager.default.fileExists(atPath: backupDirectory.path) {
            let backupValues = try backupDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard backupValues.isDirectory == true, backupValues.isSymbolicLink != true else {
                throw GitToolConfigurationError.unsafeConfigurationPath
            }
        }
    }

    private func values(for key: String) throws -> [String] {
        let result = try git(["config", "--null", "--file", configFile.path, "--get-all", key],
                             allowMissing: true)
        guard !result.isEmpty else { return [] }
        return result.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private func setValues(_ values: [String], for key: String) throws {
        _ = try git(["config", "--file", configFile.path, "--unset-all", key], allowMissing: true)
        for value in values {
            _ = try git(["config", "--file", configFile.path, "--add", key, value])
        }
    }

    private func restore(_ backup: Backup) throws {
        for key in Self.keys {
            let current = try values(for: key)
            guard current == backup.previous[key] || current == [backup.installed[key]!] else {
                throw GitToolConfigurationError.configurationChanged
            }
        }
        for key in Self.keys { try setValues(backup.previous[key] ?? [], for: key) }
    }

    private func readBackup() throws -> Backup {
        let attributes = try FileManager.default.attributesOfItem(atPath: backupFile.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: backupFile),
              let backup = try? JSONDecoder().decode(Backup.self, from: data),
              backup.configurationPath == configFile.path,
              Set(backup.previous.keys) == Set(Self.keys),
              Set(backup.installed.keys) == Set(Self.keys) else {
            throw GitToolConfigurationError.backupInvalid
        }
        return backup
    }

    private func writeBackup(_ backup: Backup) throws {
        let data = try JSONEncoder().encode(backup)
        let fd = Darwin.open(backupFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GitToolConfigurationError.backupInvalid }
        var succeeded = false
        defer {
            Darwin.close(fd)
            if !succeeded { unlink(backupFile.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw GitToolConfigurationError.backupInvalid
                }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw GitToolConfigurationError.backupInvalid }
        succeeded = true
    }

    private func git(_ arguments: [String], allowMissing: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 ||
                (allowMissing && [1, 5].contains(process.terminationStatus)) else {
            throw GitToolConfigurationError.gitFailed
        }
        return process.terminationStatus == 0 ? data : Data()
    }
}
