import Foundation
import Testing
@testable import GitCore

@Test func pathTreeGroupsNestedChangesAndKeepsFileDirectoryCollision() {
    let roots = GitPathTree.build(paths: ["README.md", "src/main.swift", "src/lib/io.swift",
                                          "src/lib/other.swift", "src/main.swift", "a", "a/b"])
    #expect(roots.map(\.name) == ["a", "src", "README.md"])
    let a = roots[0]
    #expect(a.isFile && a.children?.first?.path == "a/b")
    let src = roots[1]
    #expect(!src.isFile)
    #expect(src.children?.map(\.name) == ["lib", "main.swift"])
    #expect(src.children?.first?.children?.map(\.path) == ["src/lib/io.swift", "src/lib/other.swift"])
}

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
    try Data("new\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
    let untracked = try git.status(in: root).first { $0.path == "untracked.txt" }
    #expect(untracked?.isUntracked == true)
    #expect(untracked?.isPartiallyStaged == false)
}

@Test func commitHistoryAndFileBlobsHandleSpacesAndRootCommit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q"])
    let file = root.appendingPathComponent("a file.txt")
    try Data("before\n".utf8).write(to: file)
    try git.run(in: root, ["add", "--", "a file.txt"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                           "commit", "-qm", "first"])
    try Data("after\n".utf8).write(to: file)
    try git.run(in: root, ["add", "--", "a file.txt"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                           "commit", "-qm", "second"])

    let history = try git.commitHistory(in: root)
    #expect(history.count == 2)
    #expect(history.map(\.subject) == ["second", "first"])
    #expect(history[0].parents == [history[1].id])
    #expect(try git.changedPaths(in: root, for: history[0]) == ["a file.txt"])
    #expect(try git.changedPaths(in: root, for: history[1]) == ["a file.txt"])
    #expect(try git.file(in: root, at: history[0].id, path: "a file.txt") == Data("after\n".utf8))
    #expect(try git.file(in: root, at: history[1].id, path: "a file.txt") == Data("before\n".utf8))
    try Data("staged\n".utf8).write(to: file)
    try git.run(in: root, ["add", "--", "a file.txt"])
    try Data("working\n".utf8).write(to: file)
    #expect(try git.headFile(in: root, path: "a file.txt") == Data("after\n".utf8))
    #expect(try git.indexFile(in: root, path: "a file.txt") == Data("staged\n".utf8))
    #expect(try git.workingFile(in: root, path: "a file.txt") == Data("working\n".utf8))
    let partial = try git.status(in: root)
    #expect(partial.first?.isPartiallyStaged == true)
    #expect(throws: GitError.self) {
        try git.file(in: root, at: history[0].id, path: "../escape.txt")
    }
}

@Test func revisionComparisonKeepsRenameSourcePath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q"])
    try Data("unchanged body\n".utf8).write(to: root.appendingPathComponent("old name.txt"))
    try git.run(in: root, ["add", "--", "old name.txt"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"])
    let before = try git.resolveCommit(in: root, ref: "HEAD")
    try git.run(in: root, ["mv", "--", "old name.txt", "new name.txt"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid", "commit", "-qam", "rename"])
    let after = try git.resolveCommit(in: root, ref: "HEAD")

    let changes = try git.changes(in: root, from: before, to: after)
    #expect(changes.count == 1)
    #expect(changes[0].status.hasPrefix("R"))
    #expect(changes[0].originalPath == "old name.txt")
    #expect(changes[0].path == "new name.txt")
    #expect(try git.file(in: root, at: before, path: changes[0].originalPath!) ==
            git.file(in: root, at: after, path: changes[0].path))
    let revisions = try git.fileRevisions(in: root, path: "new name.txt")
    #expect(revisions.count == 2)
    #expect(revisions[0].path == "new name.txt")
    #expect(revisions[0].parentPath == "old name.txt")
    #expect(revisions[1].path == "old name.txt")
}

@Test func linkedWorktreesAreDiscoveredAndOpenable() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = parent.appendingPathComponent("primary")
    let linked = parent.appendingPathComponent("linked copy")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q"])
    try Data("first\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
    try git.run(in: root, ["add", "--", "sample.txt"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"])
    try git.run(in: root, ["worktree", "add", "--detach", "-q", linked.path, "HEAD"])

    let worktrees = try git.worktrees(in: root)
    #expect(worktrees.count == 2)
    #expect(worktrees.contains { $0.root.lastPathComponent == "primary" && !$0.isDetached })
    #expect(worktrees.contains { $0.root.lastPathComponent == "linked copy" && $0.isDetached })
    #expect(try git.repository(at: linked).root.lastPathComponent == "linked copy")
}

@Test func unmergedIndexExposesBaseOursAndTheirsForResolution() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    func commit(_ message: String) throws {
        try git.run(in: root, ["add", "--", "conflict file.txt"])
        try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                               "-c", "user.email=test@example.invalid", "commit", "-qm", message])
    }
    let file = root.appendingPathComponent("conflict file.txt")
    try git.run(in: root, ["init", "-q"])
    try Data("header\nbase\nfooter\n".utf8).write(to: file)
    try commit("base")
    let cleanStages = try git.conflictStages(in: root, path: "conflict file.txt")
    #expect(cleanStages?.base == nil)
    try git.run(in: root, ["switch", "-q", "-c", "ours"])
    try Data("header\nours\nfooter\n".utf8).write(to: file)
    try commit("ours")
    try git.run(in: root, ["switch", "-q", "-c", "theirs", "HEAD~1"])
    try Data("header\ntheirs\nfooter\n".utf8).write(to: file)
    try commit("theirs")
    try git.run(in: root, ["switch", "-q", "ours"])
    _ = try? git.run(in: root, ["merge", "--no-ff", "--no-edit", "theirs"])

    let entry = try #require(git.status(in: root).first { $0.path == "conflict file.txt" })
    #expect(entry.isUnmerged)
    #expect(!entry.isPartiallyStaged)
    let loadedStages = try git.conflictStages(in: root, path: entry.path)
    let stages = try #require(loadedStages)
    #expect(stages.base == Data("header\nbase\nfooter\n".utf8))
    #expect(stages.ours == Data("header\nours\nfooter\n".utf8))
    #expect(stages.theirs == Data("header\ntheirs\nfooter\n".utf8))
    #expect(throws: GitError.self) { try git.indexFile(in: root, path: entry.path) }
}

@Test func historyGraphAndRefsIncludeMergeBranchesAndAnnotatedTag() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q", "-b", "main"])
    func commit(_ name: String, file: String) throws {
        try Data(name.utf8).write(to: root.appendingPathComponent(file))
        try git.run(in: root, ["add", "--", file])
        try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                               "-c", "user.email=test@example.invalid", "commit", "-qm", name])
    }
    try commit("base", file: "base.txt")
    try git.run(in: root, ["switch", "-q", "-c", "side"])
    try commit("side", file: "side.txt")
    let side = try git.resolveCommit(in: root, ref: "HEAD")
    try git.run(in: root, ["switch", "-q", "main"])
    try commit("main", file: "main.txt")
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid",
                           "merge", "-q", "--no-ff", "-m", "merge", "side"])
    let merged = try git.resolveCommit(in: root, ref: "HEAD")
    try git.run(in: root, ["-c", "tag.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid", "tag", "-a", "v1", "-m", "release"])

    let refs = try git.refs(in: root)
    #expect(refs.first { $0.name == "refs/heads/main" }?.commitID == merged)
    #expect(refs.first { $0.name == "refs/heads/side" }?.commitID == side)
    #expect(refs.first { $0.name == "refs/tags/v1" }?.commitID == merged)
    #expect(refs.first { $0.name == "refs/tags/v1" }?.kind == .tag)
    #expect(refs.first { $0.name == "refs/tags/v1" }?.displayName == "v1")

    let commits = try git.commitHistory(in: root)
    #expect(commits.count == 4)
    #expect(commits.first?.id == merged)
    let graph = GitHistoryGraph.rows(for: commits)
    #expect(graph.map(\.commitID) == commits.map(\.id))
    #expect(graph.first?.segments.filter { $0.fromRowFraction == 0.5 }.count == 2)
    #expect(graph.allSatisfy { $0.nodeLane >= 0 && $0.nodeLane < $0.laneCount })
    #expect(graph.allSatisfy { row in
        row.segments.allSatisfy { segment in
            segment.fromLane >= 0 && segment.toLane >= 0 &&
            segment.fromLane < row.laneCount && segment.toLane < row.laneCount
        }
    })
}

@Test func submoduleChangesRemainCommitPointersAcrossTreeIndexAndWorkingCopy() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    let root = parent.appendingPathComponent("parent")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let git = GitClient()
    let author = ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                  "-c", "user.email=test@example.invalid"]
    try git.run(in: source, ["init", "-q", "-b", "main"])
    try Data("first\n".utf8).write(to: source.appendingPathComponent("item.txt"))
    try git.run(in: source, ["add", "--", "item.txt"])
    try git.run(in: source, author + ["commit", "-qm", "first"])
    let original = try git.resolveCommit(in: source, ref: "HEAD")

    try git.run(in: root, ["init", "-q", "-b", "main"])
    try git.run(in: root, ["-c", "protocol.file.allow=always", "submodule", "add", "-q",
                           source.path, "nested module"])
    try git.run(in: root, author + ["commit", "-qam", "submodule"])
    let parentCommit = try git.resolveCommit(in: root, ref: "HEAD")
    let module = root.appendingPathComponent("nested module")
    #expect(try git.treeItem(in: root, at: parentCommit, path: "nested module") == .gitlink(original))
    #expect(try git.indexItem(in: root, path: "nested module") == .gitlink(original))
    #expect(try git.workingItem(in: root, path: "nested module") == .gitlink(original))
    #expect(throws: GitError.self) { try git.file(in: root, at: parentCommit, path: "nested module") }

    try Data("second\n".utf8).write(to: module.appendingPathComponent("item.txt"))
    try git.run(in: module, ["add", "--", "item.txt"])
    try git.run(in: module, author + ["commit", "-qm", "second"])
    let updated = try git.resolveCommit(in: module, ref: "HEAD")
    #expect(updated != original)
    #expect(try git.workingItem(in: root, path: "nested module") == .gitlink(updated))
    let status = try #require(git.status(in: root).first { $0.path == "nested module" })
    #expect(status.worktreeStatus == "M")
}

@Test func lfsPointerAndBinaryBlobStayLocalAndExact() throws {
    let pointer = Data(("version https://git-lfs.github.com/spec/v1\n" +
                        "oid sha256:" + String(repeating: "a", count: 64) + "\n" +
                        "size 123456\n").utf8)
    #expect(GitLFSPointer.parse(pointer)?.size == 123_456)
    #expect(GitLFSPointer.parse(pointer)?.objectID == String(repeating: "a", count: 64))
    #expect(GitLFSPointer.parse(Data("version https://git-lfs.github.com/spec/v1\nsize 2\n".utf8)) == nil)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitClient()
    try git.run(in: root, ["init", "-q"])
    let binary = Data([0, 0x80, 0xff, 0x41])
    try binary.write(to: root.appendingPathComponent("image.dat"))
    try pointer.write(to: root.appendingPathComponent("object.lfs"))
    try git.run(in: root, ["add", "--", "image.dat", "object.lfs"])
    try git.run(in: root, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                           "-c", "user.email=test@example.invalid", "commit", "-qm", "fixtures"])
    let commit = try git.resolveCommit(in: root, ref: "HEAD")
    #expect(try git.treeItem(in: root, at: commit, path: "image.dat") == .blob(binary))
    #expect(try git.treeItem(in: root, at: commit, path: "object.lfs") == .blob(pointer))
    #expect(try git.indexItem(in: root, path: "image.dat") == .blob(binary))
    #expect(try git.workingItem(in: root, path: "image.dat") == .blob(binary))
}

