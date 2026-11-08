import Foundation
import Testing
@testable import GitCore

@Test func gitToolSettingsInstallAndRestorePreviousValues() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("test.gitconfig")
    try Data().write(to: config)
    let tool = root.appendingPathComponent("vel'lo graph")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let git = GitClient()
    try git.run(in: root, ["config", "--file", config.path, "--add", "diff.tool", "old"])
    try git.run(in: root, ["config", "--file", config.path, "--add", "diff.tool", "second"])
    try git.run(in: root, ["config", "--file", config.path, "--add", "merge.tool", "oldmerge"])
    try git.run(in: root, ["config", "--file", config.path, "--add", "user.name", "Keep Me"])
    let configuration = GitToolConfiguration(configFile: config,
                                              backupDirectory: root.appendingPathComponent("backups"),
                                              cliExecutable: tool)
    let preview = try configuration.preview()
    #expect(preview.count == 5)
    #expect(preview.first { $0.key == "diff.tool" }?.replacesExistingValue == true)
    #expect(preview.first { $0.key == "difftool.vellograph.cmd" }?.newValue.contains("'\\''") == true)
    try configuration.install()
    try configuration.install() // Repeating a completed install is harmless.
    let backupPermissions = try FileManager.default.attributesOfItem(atPath: configuration.backupFile.path)[.posixPermissions] as? NSNumber
    #expect((backupPermissions?.intValue ?? 0) & 0o077 == 0)
    #expect(try String(decoding: git.run(in: root, ["config", "--file", config.path,
                                                   "--get", "diff.tool"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "vellograph")
    try configuration.uninstall()
    let restored = try String(decoding: git.run(in: root, ["config", "--file", config.path,
                                                       "--get-all", "diff.tool"]), as: UTF8.self)
    #expect(restored.split(separator: "\n").map(String.init) == ["old", "second"])
    #expect(try String(decoding: git.run(in: root, ["config", "--file", config.path,
                                                   "--get", "merge.tool"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "oldmerge")
    #expect(try String(decoding: git.run(in: root, ["config", "--file", config.path,
                                                   "--get", "user.name"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "Keep Me")
    #expect(!FileManager.default.fileExists(atPath: configuration.backupFile.path))
}

@Test func gitToolUninstallRefusesToOverwriteAnExternalEdit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("test.gitconfig")
    try Data().write(to: config)
    let configuration = GitToolConfiguration(configFile: config,
                                              backupDirectory: root.appendingPathComponent("backups"),
                                              cliExecutable: URL(fileURLWithPath: "/usr/bin/git"))
    try configuration.install()
    let git = GitClient()
    try git.run(in: root, ["config", "--file", config.path, "--replace-all", "merge.tool", "external"])
    #expect(throws: GitToolConfigurationError.self) { try configuration.uninstall() }
    #expect(FileManager.default.fileExists(atPath: configuration.backupFile.path))
    #expect(try String(decoding: git.run(in: root, ["config", "--file", config.path,
                                                   "--get", "merge.tool"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "external")
}

@Test func installedDifftoolInvokesTheConfiguredExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q"])
    let file = root.appendingPathComponent("sample.txt")
    try Data("before\n".utf8).write(to: file)
    try git.run(in: root, ["add", "--", "sample.txt"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"])
    try Data("after\n".utf8).write(to: file)
    let log = root.appendingPathComponent("invocation.txt")
    let leftLog = root.appendingPathComponent("left.txt")
    let rightLog = root.appendingPathComponent("right.txt")
    let tool = root.appendingPathComponent("vel'lo graph")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(log.path)'\ncat \"$4\" > '\(leftLog.path)'\ncat \"$5\" > '\(rightLog.path)'\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let config = try GitToolConfiguration.repositoryConfigurationFile(root)
    let configuration = GitToolConfiguration(configFile: config,
                                              backupDirectory: root.appendingPathComponent("backups"),
                                              cliExecutable: tool)
    try configuration.install()
    try git.run(in: root, ["difftool", "--no-prompt", "--", "sample.txt"])
    let arguments = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(arguments.count == 5)
    #expect(arguments[0...2] == ["diff", "--wait", "--"])
    #expect(try String(contentsOf: leftLog, encoding: .utf8) == "before\n")
    #expect(try String(contentsOf: rightLog, encoding: .utf8) == "after\n")
    try configuration.uninstall()
}

@Test func installedMergetoolReceivesBaseSidesAndOutput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q", "-b", "main"])
    let file = root.appendingPathComponent("sample.txt")
    try Data("base\n".utf8).write(to: file)
    try git.run(in: root, ["add", "--", "sample.txt"])
    let identity = ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                    "-c", "user.email=test@example.invalid"]
    try git.run(in: root, identity + ["commit", "-qm", "base"])
    try git.run(in: root, ["switch", "-qc", "other"])
    try Data("remote\n".utf8).write(to: file)
    try git.run(in: root, identity + ["commit", "-qam", "remote"])
    try git.run(in: root, ["switch", "-q", "main"])
    try Data("local\n".utf8).write(to: file)
    try git.run(in: root, identity + ["commit", "-qam", "local"])
    _ = try? git.run(in: root, ["merge", "--no-edit", "other"])

    let argumentsLog = root.appendingPathComponent("merge-arguments.txt")
    let baseLog = root.appendingPathComponent("base.txt")
    let localLog = root.appendingPathComponent("local.txt")
    let remoteLog = root.appendingPathComponent("remote.txt")
    let tool = root.appendingPathComponent("vel'lo graph")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > '\(argumentsLog.path)'
    cat "$3" > '\(baseLog.path)'
    cat "$7" > '\(localLog.path)'
    cat "$8" > '\(remoteLog.path)'
    cp "$7" "$5"
    """
    try Data((script + "\n").utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let config = try GitToolConfiguration.repositoryConfigurationFile(root)
    let configuration = GitToolConfiguration(configFile: config,
                                              backupDirectory: root.appendingPathComponent("backups"),
                                              cliExecutable: tool)
    try configuration.install()
    try git.run(in: root, ["mergetool", "--no-prompt", "--", "sample.txt"])
    let arguments = try String(contentsOf: argumentsLog, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(arguments.count == 8)
    #expect(arguments[0] == "merge")
    #expect(arguments[1] == "--base")
    #expect(arguments[3] == "--output")
    #expect(arguments[5] == "--")
    #expect(try String(contentsOf: baseLog, encoding: .utf8) == "base\n")
    #expect(try String(contentsOf: localLog, encoding: .utf8) == "local\n")
    #expect(try String(contentsOf: remoteLog, encoding: .utf8) == "remote\n")
    #expect(try String(contentsOf: file, encoding: .utf8) == "local\n")
    try configuration.uninstall()
}
