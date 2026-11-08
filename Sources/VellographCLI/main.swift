import Darwin
import Foundation
import GitCore
import IPCBridge

private enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        }
    }
}

private enum CommandLineClient {
    private struct ParsedCommand {
        let request: IPCRequest
        let capturedStdinPath: String?
    }

    static let usage = """
    Usage:
      vellograph diff [--wait] [--label NAME] [--] SOURCE [SOURCE]
      vellograph merge --base BASE --output OUTPUT -- LOCAL REMOTE
      vellograph changeset --repo PATH --from REF --to REF
      vellograph working-copy --repo PATH
      vellograph git-tool preview (--global | --repo PATH) [--cli PATH]
      vellograph git-tool install (--global | --repo PATH) [--cli PATH] --yes
      vellograph git-tool uninstall (--global | --repo PATH)

    Use - as one diff source to capture standard input. Exit codes: 0 completed,
    1 cancelled or unresolved, 2 invalid input or transport failure.
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        if ["help", "--help", "-h"].contains(arguments.first ?? ""), arguments.count == 1 {
            print(usage)
            return 0
        }
        if arguments.first == "git-tool" {
            return try runGitTool(Array(arguments.dropFirst()))
        }
        let command = try parse(arguments)
        do {
            let response = try deliver(command.request)
            if response.status != 0 {
                if let path = command.capturedStdinPath { unlink(path) }
                if let message = response.message { fputs(message + "\n", stderr) }
            }
            return response.status
        } catch {
            if let path = command.capturedStdinPath { unlink(path) }
            throw CLIError.usage(error.localizedDescription)
        }
    }

    private static func runGitTool(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first,
              ["preview", "install", "uninstall"].contains(action) else {
            throw CLIError.usage(usage)
        }
        var global = false
        var repository: String?
        var cli: String?
        var confirmed = false
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--global": global = true
            case "--yes": confirmed = true
            case "--repo", "--cli":
                guard index < arguments.count else { throw CLIError.usage("Missing value for \(option).") }
                if option == "--repo" { repository = arguments[index] }
                else { cli = arguments[index] }
                index += 1
            default: throw CLIError.usage("Unknown option \(option).\n\(usage)")
            }
        }
        guard global != (repository != nil),
              (action == "install" ? confirmed : !confirmed),
              action != "uninstall" || cli == nil else {
            throw CLIError.usage("Choose exactly one Git scope. Install requires --yes.\n\(usage)")
        }
        let configurationFile = try global
            ? GitToolConfiguration.globalConfigurationFile()
            : GitToolConfiguration.repositoryConfigurationFile(
                URL(fileURLWithPath: absolutePath(repository!)))
        let backupDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask)[0]
            .appendingPathComponent("Vellograph/GitToolBackups", isDirectory: true)
        let currentExecutable = cli.map(absolutePath) ??
            Bundle.main.executableURL?.path ?? absolutePath(CommandLine.arguments[0])
        let configuration = GitToolConfiguration(
            configFile: configurationFile, backupDirectory: backupDirectory,
            cliExecutable: URL(fileURLWithPath: currentExecutable)
        )
        switch action {
        case "preview":
            print("Git configuration: \(configuration.configFile.path)")
            print("Vellograph executable: \(configuration.cliExecutable.path)")
            if configuration.cliExecutable.path.contains("/.build/") {
                print("Development build path: use --cli with a stable installed path before installing.")
            }
            print("Changes to apply:")
            for change in try configuration.preview() {
                print("  \(change.key) = \(change.newValue)\(change.replacesExistingValue ? " (replaces existing value)" : "")")
            }
            print("Install with the same scope and --yes. A private backup allows uninstall.")
        case "install":
            try configuration.install()
            print("Installed Vellograph Git tool settings in \(configuration.configFile.path).")
            print("Previous values are saved at \(configuration.backupFile.path).")
        case "uninstall":
            try configuration.uninstall()
            print("Restored previous Git tool settings in \(configuration.configFile.path).")
        default: break
        }
        return 0
    }

    private static func parse(_ arguments: [String]) throws -> ParsedCommand {
        guard let command = arguments.first else { throw CLIError.usage(usage) }
        var values: [String: String] = [:]
        var positions: [String] = []
        var wait = false
        var positionalOnly = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" && !positionalOnly { positionalOnly = true; continue }
            if !positionalOnly && argument == "--wait" { wait = true; continue }
            if !positionalOnly && ["--label", "--base", "--output", "--repo", "--from", "--to"].contains(argument) {
                guard index < arguments.count else { throw CLIError.usage("Missing value for \(argument).\n\(usage)") }
                guard values[argument] == nil else {
                    throw CLIError.usage("Option \(argument) may only appear once.")
                }
                values[argument] = arguments[index]
                index += 1
                continue
            }
            if !positionalOnly && argument.hasPrefix("-") && argument != "-" {
                throw CLIError.usage("Unknown option \(argument).\n\(usage)")
            }
            positions.append(argument)
        }
        switch command {
        case "diff":
            guard (1...2).contains(positions.count),
                  Set(values.keys).isSubset(of: ["--label"]) else {
                throw CLIError.usage(usage)
            }
            guard positions.filter({ $0 == "-" }).count <= 1 else {
                throw CLIError.usage("Standard input can only appear once.")
            }
            let validated = try positions.map { value in
                value == "-" ? value : try existingPath(value)
            }
            let stdinPath = validated.contains("-") ? try captureStdin() : nil
            let paths = validated.map { $0 == "-" ? stdinPath! : $0 }
            return ParsedCommand(request: IPCRequest(action: .diff, paths: paths,
                                                      wait: wait, label: values["--label"]),
                                 capturedStdinPath: stdinPath)
        case "merge":
            guard positions.count == 2, let base = values["--base"], let output = values["--output"],
                  Set(values.keys) == ["--base", "--output"] else {
                throw CLIError.usage(usage)
            }
            return ParsedCommand(request: IPCRequest(
                action: .merge,
                paths: try [base, positions[0], positions[1]].map(existingPath),
                wait: true, output: absolutePath(output)), capturedStdinPath: nil)
        case "changeset":
            guard positions.isEmpty, !wait,
                  let repo = values["--repo"], let from = values["--from"], let to = values["--to"],
                  Set(values.keys) == ["--repo", "--from", "--to"] else {
                throw CLIError.usage(usage)
            }
            return ParsedCommand(request: IPCRequest(
                action: .changeset, repository: try existingPath(repo),
                fromRef: from, toRef: to), capturedStdinPath: nil)
        case "working-copy":
            guard positions.isEmpty, !wait, let repo = values["--repo"],
                  Set(values.keys) == ["--repo"] else {
                throw CLIError.usage(usage)
            }
            return ParsedCommand(request: IPCRequest(
                action: .workingCopy, repository: try existingPath(repo)), capturedStdinPath: nil)
        default:
            throw CLIError.usage("Unknown command \(command).\n\(usage)")
        }
    }

    private static func existingPath(_ value: String) throws -> String {
        let path = absolutePath(value)
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.usage("Source does not exist: \(value)")
        }
        return path
    }

    private static func absolutePath(_ value: String) -> String {
        let expanded = (value as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: root).standardizedFileURL.path
    }

    private static func captureStdin() throws -> String {
        let directory = ManagedSnapshots.directory
        try ManagedSnapshots.prepareDirectory()
        let path = directory.appendingPathComponent("stdin-\(UUID().uuidString).txt").path
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw CLIError.usage("Could not create a private standard-input snapshot.") }
        var completed = false
        defer {
            Darwin.close(fd)
            if !completed { unlink(path) }
        }
        var total = 0
        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            total += chunk.count
            guard total <= 100_000_000 else { throw CLIError.usage("Standard input exceeds 100 MB.") }
            try chunk.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var sent = 0
                while sent < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: sent), buffer.count - sent)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw CLIError.usage("Could not save the standard-input snapshot.")
                    }
                    sent += count
                }
            }
        }
        guard fsync(fd) == 0 else { throw CLIError.usage("Could not finish the standard-input snapshot.") }
        completed = true
        return path
    }

    private static func deliver(_ request: IPCRequest) throws -> IPCResponse {
        if let response = try? LocalSocketClient.send(request) { return response }
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-b", "io.github.michaeldadi.vellograph"]
        try launch.run()
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else {
            throw CLIError.usage("Could not launch Vellograph. Open the app and retry.")
        }
        for _ in 0..<150 {
            if let response = try? LocalSocketClient.send(request) { return response }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CLIError.usage("Vellograph did not accept the command. Open the app and retry.")
    }
}

do {
    let status = try CommandLineClient.run(Array(CommandLine.arguments.dropFirst()))
    exit(status)
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(2)
}
