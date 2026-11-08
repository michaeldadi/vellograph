import Foundation
import Testing
@testable import GitCore

private func temporaryGitRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try GitClient().run(in: root, ["init", "-q", "-b", "main"])
    return root
}

private func commitConflictFile(_ root: URL, message: String) throws {
    let git = GitClient()
    try git.run(in: root, ["add", "-A", "--", "conflict.dat"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid", "commit", "-qm", message])
}

@Test func binaryConflictChoiceKeepsExactBytesAndUnmergedIndex() throws {
    let root = try temporaryGitRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    let file = root.appendingPathComponent("conflict.dat")
    try Data([0, 1, 2]).write(to: file)
    try commitConflictFile(root, message: "base")
    try git.run(in: root, ["switch", "-q", "-c", "ours"])
    let ours = Data([0, 9, 2])
    try ours.write(to: file)
    try commitConflictFile(root, message: "ours")
    try git.run(in: root, ["switch", "-q", "-c", "theirs", "HEAD~1"])
    let theirs = Data([0, 7, 2])
    try theirs.write(to: file)
    try commitConflictFile(root, message: "theirs")
    try git.run(in: root, ["switch", "-q", "ours"])
    _ = try? git.run(in: root, ["merge", "--no-ff", "--no-edit", "theirs"])

    let loadedStages = try git.conflictStages(in: root, path: "conflict.dat")
    let stages = try #require(loadedStages)
    #expect(stages.ours == ours)
    #expect(stages.theirs == theirs)
    let working = try git.workingFile(in: root, path: "conflict.dat")
    _ = try git.saveWholeFileConflict(in: root, path: "conflict.dat",
                                      expectedStages: stages, expectedWorkingFile: working,
                                      choice: .theirs)
    #expect(try Data(contentsOf: file) == theirs)
    #expect(try git.conflictStages(in: root, path: "conflict.dat") != nil)
    try git.run(in: root, ["add", "--", "conflict.dat"])
    #expect(throws: GitError.self) {
        _ = try git.saveWholeFileConflict(in: root, path: "conflict.dat",
                                          expectedStages: stages, expectedWorkingFile: theirs,
                                          choice: .ours)
    }
    #expect(try Data(contentsOf: file) == theirs)
}

@Test func deletedGitSideRemovesWorkingFileWithRecovery() throws {
    let root = try temporaryGitRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    let file = root.appendingPathComponent("conflict.dat")
    try Data("base\n".utf8).write(to: file)
    try commitConflictFile(root, message: "base")
    try git.run(in: root, ["switch", "-q", "-c", "ours"])
    try FileManager.default.removeItem(at: file)
    try commitConflictFile(root, message: "delete")
    try git.run(in: root, ["switch", "-q", "-c", "theirs", "HEAD~1"])
    try Data("modified\n".utf8).write(to: file)
    try commitConflictFile(root, message: "modify")
    try git.run(in: root, ["switch", "-q", "ours"])
    _ = try? git.run(in: root, ["merge", "--no-ff", "--no-edit", "theirs"])

    let loadedStages = try git.conflictStages(in: root, path: "conflict.dat")
    let stages = try #require(loadedStages)
    #expect(stages.ours == nil)
    #expect(stages.theirs == Data("modified\n".utf8))
    let working = try git.workingFile(in: root, path: "conflict.dat")
    let result = try git.saveWholeFileConflict(in: root, path: "conflict.dat",
                                               expectedStages: stages, expectedWorkingFile: working,
                                               choice: .ours)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    if let working { #expect(try Data(contentsOf: result.recoveryURL!) == working) }
    #expect(try git.conflictStages(in: root, path: "conflict.dat") != nil)
}
