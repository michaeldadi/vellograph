import Foundation
import Testing
@testable import GitCore

@Test func statusIncludesUntrackedAndModifiedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q"])
    let a = root.appendingPathComponent("a file.txt")
    try Data("one\n".utf8).write(to: a)
    try git.run(in: root, ["add", "--", "a file.txt"])
    let initial = try git.status(in: root)
    #expect(initial.count == 1)
    #expect(initial[0].path == "a file.txt")
    try Data("two\n".utf8).write(to: a)
    let changed = try git.status(in: root)
    #expect(changed[0].isPartiallyStaged)
}

