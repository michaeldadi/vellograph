@testable import FolderCore
import Foundation
import Testing

@Test func selectedCopyPreservesExtrasAndKeepsRecovery() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("new".utf8).write(to: source.appendingPathComponent("file.txt"))
    try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
    try Data("keep".utf8).write(to: destination.appendingPathComponent("extra.txt"))

    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["file.txt"])
    #expect(plan.actions.map(\.kind) == [.replace])
    let result = try plan.apply()
    #expect(result.appliedCount == 1)
    #expect(try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8) == "new")
    #expect(try String(contentsOf: destination.appendingPathComponent("extra.txt"), encoding: .utf8) == "keep")
    #expect(try String(contentsOf: result.recoveryFolder!.appendingPathComponent("file.txt"), encoding: .utf8) == "old")
}

@Test func changedSourceInvalidatesPreviewBeforeWriting() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceFile = source.appendingPathComponent("file.txt")
    let destinationFile = destination.appendingPathComponent("file.txt")
    try Data("abc".utf8).write(to: sourceFile)
    try Data("old".utf8).write(to: destinationFile)
    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["file.txt"])
    try Data("xyz".utf8).write(to: sourceFile)
    #expect(throws: FolderOperationError.self) { try plan.apply() }
    #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "old")
}

@Test func changedDestinationInvalidatesPreviewBeforeWriting() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("new".utf8).write(to: source.appendingPathComponent("file.txt"))
    let destinationFile = destination.appendingPathComponent("file.txt")
    try Data("old".utf8).write(to: destinationFile)
    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["file.txt"])
    try Data("external edit".utf8).write(to: destinationFile)
    #expect(throws: FolderOperationError.self) { try plan.apply() }
    #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "external edit")
}

@Test func destinationChangedAfterFinalCheckIsRestoredWithoutWritingSource() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceFile = source.appendingPathComponent("file.txt")
    let destinationFile = destination.appendingPathComponent("file.txt")
    try Data("source".utf8).write(to: sourceFile)
    try Data("previewed".utf8).write(to: destinationFile)
    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["file.txt"])
    #expect(throws: FolderOperationError.stalePreview("file.txt")) {
        try plan.apply(afterFinalTargetCheck: { action in
            if action.path == "file.txt" {
                try Data("external edit".utf8).write(to: destinationFile)
            }
        })
    }
    #expect(try String(contentsOf: destinationFile, encoding: .utf8) == "external edit")
    #expect(try String(contentsOf: sourceFile, encoding: .utf8) == "source")
}

@Test func replacingDestinationRootInvalidatesIdenticalLookingPreview() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("new".utf8).write(to: source.appendingPathComponent("file.txt"))
    try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["file.txt"])
    try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("original"))
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))

    #expect(throws: FolderOperationError.self) { try plan.apply() }
    #expect(try String(contentsOf: destination.appendingPathComponent("file.txt"),
                       encoding: .utf8) == "old")
}

@Test func nestedSelectionListsAndCreatesMissingParents() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = source.appendingPathComponent("top/sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("nested".utf8).write(to: nested.appendingPathComponent("item.txt"))
    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["top/sub/item.txt"],
                                                options: .init(includeHidden: true))
    #expect(plan.actions.map(\.path) == ["top", "top/sub", "top/sub/item.txt"])
    #expect(plan.actions.map(\.kind) == [.createDirectory, .createDirectory, .create])
    _ = try plan.apply()
    #expect(try String(contentsOf: destination.appendingPathComponent("top/sub/item.txt"),
                       encoding: .utf8) == "nested")
}

@Test func cloneListsAndRecoversDestinationOnlyItems() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("source".utf8).write(to: source.appendingPathComponent("present.txt"))
    try Data("extra".utf8).write(to: destination.appendingPathComponent("extra.txt"))
    let plan = try FolderOperationPlan.makeClone(from: source, to: destination)
    #expect(plan.actions.contains { $0.path == "extra.txt" && $0.kind == .remove })
    let result = try plan.apply()
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("extra.txt").path))
    #expect(try String(contentsOf: result.recoveryFolder!.appendingPathComponent("extra.txt"), encoding: .utf8) == "extra")
    #expect(try String(contentsOf: destination.appendingPathComponent("present.txt"), encoding: .utf8) == "source")
}

@Test func cloneRecoversNestedDestinationOnlyTree() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = destination.appendingPathComponent("extra/sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("keep for recovery".utf8).write(to: nested.appendingPathComponent("item.txt"))
    let plan = try FolderOperationPlan.makeClone(from: source, to: destination)
    #expect(plan.actions.map(\.path).contains("extra/sub/item.txt"))
    let result = try plan.apply()
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("extra").path))
    #expect(try String(contentsOf: result.recoveryFolder!.appendingPathComponent("extra/sub/item.txt"),
                       encoding: .utf8) == "keep for recovery")
}

@Test func cloneKeepsExcludedDescendantsAndTheirDirectories() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let extra = destination.appendingPathComponent("extra", isDirectory: true)
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    try Data("remove".utf8).write(to: extra.appendingPathComponent("visible.txt"))
    try Data("keep hidden".utf8).write(to: extra.appendingPathComponent(".secret"))
    try Data("keep ignored".utf8).write(to: extra.appendingPathComponent("ignored.txt"))
    let plan = try FolderOperationPlan.makeClone(
        from: source, to: destination,
        options: .init(ignoredPathPatterns: ["^extra/ignored\\.txt$"]))
    #expect(plan.actions.map(\.path) == ["extra/visible.txt"])
    let result = try plan.apply()
    #expect(!FileManager.default.fileExists(atPath: extra.appendingPathComponent("visible.txt").path))
    #expect(try String(contentsOf: extra.appendingPathComponent(".secret"), encoding: .utf8) == "keep hidden")
    #expect(try String(contentsOf: extra.appendingPathComponent("ignored.txt"), encoding: .utf8) == "keep ignored")
    #expect(try String(contentsOf: result.recoveryFolder!.appendingPathComponent("extra/visible.txt"),
                       encoding: .utf8) == "remove")
}

@Test func cloneRollsBackWhenHiddenFileAppearsAfterPreview() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let extra = destination.appendingPathComponent("extra", isDirectory: true)
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    try Data("visible".utf8).write(to: extra.appendingPathComponent("visible.txt"))
    let plan = try FolderOperationPlan.makeClone(from: source, to: destination)
    #expect(plan.actions.map(\.path) == ["extra/visible.txt", "extra"])
    try Data("arrived late".utf8).write(to: extra.appendingPathComponent(".secret"))

    #expect(throws: FolderOperationError.self) { try plan.apply() }
    #expect(try String(contentsOf: extra.appendingPathComponent("visible.txt"), encoding: .utf8) == "visible")
    #expect(try String(contentsOf: extra.appendingPathComponent(".secret"), encoding: .utf8) == "arrived late")
}

@Test func cloningAnEmptyDirectoryNeedsNoRecoveryCopy() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let extra = destination.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    let plan = try FolderOperationPlan.makeClone(from: source, to: destination)
    #expect(plan.actions.map(\.path) == ["empty"])
    let result = try plan.apply()
    #expect(result.recoveryFolder == nil)
    #expect(!FileManager.default.fileExists(atPath: extra.path))
}

@Test func packageDirectoriesCannotBeCopiedOrCloned() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourcePackage = source.appendingPathComponent("Example.app", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcePackage, withIntermediateDirectories: true)
    try Data("binary".utf8).write(to: sourcePackage.appendingPathComponent("Contents"))
    #expect(try sourcePackage.resourceValues(forKeys: [.isPackageKey]).isPackage == true)
    #expect(throws: FolderOperationError.self) {
        try FolderOperationPlan.makeCopy(from: source, to: destination,
                                         selectedPaths: ["Example.app/Contents"])
    }
    try FileManager.default.removeItem(at: sourcePackage)

    let destinationPackage = destination.appendingPathComponent("Existing.app", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationPackage, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: destinationPackage.appendingPathComponent("Contents"))
    #expect(throws: FolderOperationError.self) {
        try FolderOperationPlan.makeClone(from: source, to: destination)
    }
    #expect(try String(contentsOf: destinationPackage.appendingPathComponent("Contents"),
                       encoding: .utf8) == "keep")
}

@Test func copyRejectsSymbolicLinkOutsideSource() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path,
                                               withDestinationPath: "../../outside")
    #expect(throws: FolderOperationError.self) {
        try FolderOperationPlan.makeCopy(from: source, to: destination, selectedPaths: ["escape"])
    }
}

@Test func copyRejectsLinkChainEscapingSource() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("outside".utf8).write(to: root.appendingPathComponent("outside"))
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("inner").path,
        withDestinationPath: "../outside")
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("alias").path,
        withDestinationPath: "inner")
    #expect(throws: FolderOperationError.self) {
        try FolderOperationPlan.makeCopy(from: source, to: destination,
                                         selectedPaths: ["alias"])
    }
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("alias").path))
}

@Test func copyRejectsLinkThatWouldEscapeDestination() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("inside".utf8).write(to: source.appendingPathComponent("inner"))
    try Data("outside".utf8).write(to: root.appendingPathComponent("outside"))
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("alias").path,
        withDestinationPath: "inner")
    try FileManager.default.createSymbolicLink(
        atPath: destination.appendingPathComponent("inner").path,
        withDestinationPath: "../outside")
    #expect(throws: FolderOperationError.self) {
        try FolderOperationPlan.makeCopy(from: source, to: destination,
                                         selectedPaths: ["alias"])
    }
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("alias").path))
}

@Test func changedLinkChainInvalidatesCopyPreview() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("inside".utf8).write(to: source.appendingPathComponent("inner"))
    try Data("inside".utf8).write(to: destination.appendingPathComponent("inner"))
    try Data("outside".utf8).write(to: root.appendingPathComponent("outside"))
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("alias").path,
        withDestinationPath: "inner")
    let plan = try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                selectedPaths: ["alias"])
    try FileManager.default.removeItem(at: destination.appendingPathComponent("inner"))
    try FileManager.default.createSymbolicLink(
        atPath: destination.appendingPathComponent("inner").path,
        withDestinationPath: "../outside")
    #expect(throws: FolderOperationError.self) { try plan.apply() }
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("alias").path))
}

@Test func copyRejectsSymbolicLinkDestinationParent() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceSubdirectory = source.appendingPathComponent("sub", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceSubdirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: sourceSubdirectory.appendingPathComponent("item.txt"))
    try FileManager.default.createSymbolicLink(
        atPath: destination.appendingPathComponent("sub").path,
        withDestinationPath: outside.path
    )
    #expect(throws: FolderOperationError.self) {
        try FolderOperationPlan.makeCopy(
            from: source, to: destination, selectedPaths: ["sub/item.txt"]
        )
    }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("item.txt").path))
}

@Test func copyPreservesInternalSymbolicLinkWithoutFollowingIt() throws {
    let (root, source, destination) = try folders()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("target".utf8).write(to: source.appendingPathComponent("target.txt"))
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("alias.txt").path,
        withDestinationPath: "target.txt"
    )
    let plan = try FolderOperationPlan.makeCopy(
        from: source, to: destination, selectedPaths: ["alias.txt"]
    )
    _ = try plan.apply()
    let copied = destination.appendingPathComponent("alias.txt")
    #expect(try copied.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.path) == "target.txt")
}

private func folders() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    return (root, source, destination)
}
