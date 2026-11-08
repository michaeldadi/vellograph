import AppKit
import CryptoKit
import DiffCore
import DocumentCore
import FolderCore
import GitCore
import IPCBridge
import Observation
import os
import UniformTypeIdentifiers

enum ComparisonContent: Sendable {
    case text(TextComparison)
    case merge(TextMergeComparison)
    case gitWholeFileConflict(GitWholeFileConflictComparison)
    case folders(FolderComparisonSession)
    case images(URL, URL)
    case metadata(FileMetadataComparison)
    case repository(RepositoryComparison)
    case message(String)
}

struct TextComparison: Sendable {
    let sources: [URL]
    let left: TextSnapshot
    let right: TextSnapshot
    let diff: DiffResult
    let rows: [DiffDisplayRow]
    let changeRowIDs: [Int]
    let changeOperationIDs: [Int]
    let extractionNotes: [String]
    let allowsTextResolution: Bool
    let gitRange: GitRangeNavigation?
    let syntaxHint: String?
    let leftContentWidth: CGFloat
    let rightContentWidth: CGFloat

    init(sources: [URL], left: TextSnapshot, right: TextSnapshot, diff: DiffResult,
         extractionNotes: [String] = [], gitRange: GitRangeNavigation? = nil,
         syntaxHint: String? = nil, allowsTextResolution: Bool = true) {
        self.sources = sources
        self.left = left
        self.right = right
        self.diff = diff
        self.extractionNotes = extractionNotes
        self.allowsTextResolution = allowsTextResolution
        self.gitRange = gitRange
        self.syntaxHint = syntaxHint
        self.leftContentWidth = Self.contentWidth(for: left.lines)
        self.rightContentWidth = Self.contentWidth(for: right.lines)
        let rows = DiffDisplay.rows(for: diff.operations)
        self.rows = rows
        var lastChanged = false
        self.changeRowIDs = rows.compactMap { row in
            defer { lastChanged = row.isChanged }
            return row.isChanged && !lastChanged ? row.id : nil
        }
        var lastOperationChanged = false
        self.changeOperationIDs = diff.operations.enumerated().compactMap { index, operation in
            let changed: Bool
            if case .equal = operation { changed = false } else { changed = true }
            defer { lastOperationChanged = changed }
            return changed && !lastOperationChanged ? index : nil
        }
    }

    private static func contentWidth(for lines: [TextLine]) -> CGFloat {
        let longest = lines.lazy.map { $0.content.utf16.count }.max() ?? 0
        return CGFloat(min(16_384, max(450, longest * 7 + 100)))
    }

    static func load(sources: [URL]) throws -> TextComparison {
        guard (1...2).contains(sources.count) else {
            throw SnapshotError.unsupportedEncoding
        }
        let loaded = try sources.map { try DocumentTextLoader.load($0) }
        let left = sources.count == 1 ? try TextSnapshot(text: "") : loaded[0].snapshot
        let right = loaded.last!.snapshot
        let diff = try DiffEngine.compare(left.lines, right.lines)
        let notes = zip(sources, loaded).compactMap { url, document in
            document.note.map { "\(url.lastPathComponent): \($0)" }
        }
        return TextComparison(sources: sources, left: left, right: right, diff: diff,
                              extractionNotes: notes)
    }
}

private func presentGitItem(_ item: GitFileItem?, side: String) throws -> (TextSnapshot, String?, Bool) {
    guard let item else { return (try TextSnapshot(text: ""), nil, true) }
    switch item {
    case .gitlink(let commit):
        let description = commit.map { "Submodule commit \($0)\n" } ?? "Submodule is not initialized\n"
        return (try TextSnapshot(text: description),
                "\(side): Git stores this submodule as a commit pointer; its files are not included in this comparison.",
                false)
    case .blob(let data):
        if let pointer = GitLFSPointer.parse(data) {
            return (try TextSnapshot(data: data),
                    "\(side): Git LFS pointer for \(pointer.size) bytes (SHA-256 \(pointer.objectID)); the large object was not fetched.",
                    false)
        }
        if let snapshot = try? TextSnapshot(data: data) { return (snapshot, nil, true) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (try TextSnapshot(text: "Binary Git blob · \(data.count) bytes\nSHA-256 \(hash)\n"),
                "\(side): binary Git blob; showing exact size and SHA-256 because text lines are unavailable.",
                false)
    }
}

private func compareGitItems(_ left: GitFileItem?, _ right: GitFileItem?,
                             syntaxHint: String, navigation: GitRangeNavigation? = nil,
                             additionalNotes: [String] = []) throws -> TextComparison {
    let before = try presentGitItem(left, side: "Before")
    let after = try presentGitItem(right, side: "After")
    let diff = try DiffEngine.compare(before.0.lines, after.0.lines)
    return TextComparison(sources: [], left: before.0, right: after.0, diff: diff,
                          extractionNotes: [before.1, after.1].compactMap { $0 } + additionalNotes,
                          gitRange: navigation, syntaxHint: syntaxHint,
                          allowsTextResolution: before.2 && after.2)
}

struct GitRangeNavigation: Sendable {
    let repositoryRoot: URL
    let fromID: String
    let toID: String
    let changes: [GitPathChange]
    let index: Int

    func advanced(by offset: Int) -> GitRangeNavigation? {
        let next = index + offset
        guard changes.indices.contains(next) else { return nil }
        return GitRangeNavigation(repositoryRoot: repositoryRoot, fromID: fromID,
                                  toID: toID, changes: changes, index: next)
    }
}

struct TextMergeComparison: Sendable {
    let sources: [URL]
    let sourceLabels: [String]
    let snapshots: [TextSnapshot]
    let outputURL: URL?
    let expectedOutput: Data?
    let isGitConflict: Bool
}

struct GitWholeFileConflictComparison: Sendable {
    let repositoryRoot: URL
    let path: String
    let stages: GitConflictStages
    let expectedOutput: Data?

    var outputURL: URL { repositoryRoot.appendingPathComponent(path) }
}

struct RepositoryComparison: Sendable {
    let repository: GitRepository
    let fromRef: String?
    let toRef: String?
    let startInHistory: Bool

    init(repository: GitRepository, fromRef: String? = nil, toRef: String? = nil,
         startInHistory: Bool = false) {
        self.repository = repository
        self.fromRef = fromRef
        self.toRef = toRef
        self.startInHistory = startInHistory
    }
}

struct FileMetadataComparison: Sendable {
    let sources: [URL]
    let reason: String
}

struct FolderComparisonSession: Sendable {
    let left: URL
    let right: URL
    let entries: [FolderDifference]
}

struct ComparisonTab: Identifiable {
    let id: UUID
    var title: String
    let sources: [URL]
    var content: ComparisonContent
    var contentVersion: UUID = UUID()
}

struct RecentComparison: Identifiable, Codable {
    let id: UUID
    let paths: [String]
    let title: String
    let openedAt: Date
    let kind: RecentKind?
}

enum RecentKind: String, Codable {
    case comparison
    case repository
}

struct ShelfEntry: Identifiable, Codable {
    let id: UUID
    var path: String
    var label: String
    var temporary: Bool?

    var url: URL { URL(fileURLWithPath: path) }
    var isTemporary: Bool { temporary == true }
}

private struct SavedShelf: Codable {
    let entries: [ShelfEntry]
    let leftID: UUID?
    let rightID: UUID?
}

private struct SavedWorkspace: Codable {
    let tabs: [[String]]
    let selectedIndex: Int
}

@MainActor @Observable
final class WorkspaceModel {
    private let loadSignposter = OSSignposter(
        subsystem: "io.github.michaeldadi.vellograph", category: "WorkspaceLoad")
    private static let isUITesting = ProcessInfo.processInfo.environment["VELLOGRAPH_UI_TESTING"] == "1"
    private let preferences: UserDefaults
    var tabs: [ComparisonTab] = []
    var selection: UUID?
    var recentComparisons: [RecentComparison] = []
    var shelf: [ShelfEntry] = []
    var shelfLeftID: UUID?
    var shelfRightID: UUID?
    private var activeLoads = 0
    var isLoading: Bool { activeLoads > 0 }
    var errorMessage: String?
    var noticeMessage: String?
    private var didRestore = false
    private var ipcServer: LocalSocketServer?
    private var pendingCommands: [UUID: CheckedContinuation<IPCResponse, Never>] = [:]
    private var pendingMergeTabs: Set<UUID> = []

    init() {
        if Self.isUITesting {
            let suite = ProcessInfo.processInfo.environment["VELLOGRAPH_UI_TEST_SUITE"]
                ?? "io.github.michaeldadi.vellograph.ui-test.\(UUID().uuidString)"
            preferences = UserDefaults(suiteName: suite)!
        } else {
            preferences = .standard
        }
        if let data = preferences.data(forKey: "recentComparisons.v1"),
           let recent = try? JSONDecoder().decode([RecentComparison].self, from: data) {
            recentComparisons = recent
        }
        if let data = preferences.data(forKey: "sourceShelf.v1"),
           let saved = try? JSONDecoder().decode(SavedShelf.self, from: data) {
            shelf = saved.entries
            shelfLeftID = saved.leftID
            shelfRightID = saved.rightID
        }
    }

    var selectedTab: ComparisonTab? { tabs.first { $0.id == selection } }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            Task { await open(urls: panel.urls) }
        }
    }

    func chooseShelfSources() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { addToShelf(panel.urls) }
    }

    func addToShelf(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !shelf.contains(where: { $0.path == path }) else { continue }
            let entry = ShelfEntry(id: UUID(), path: path, label: url.lastPathComponent)
            shelf.append(entry)
            if shelfLeftID == nil { shelfLeftID = entry.id }
            else if shelfRightID == nil { shelfRightID = entry.id }
        }
        saveShelf()
    }

    func selectShelfLeft(_ id: UUID?) {
        shelfLeftID = id
        saveShelf()
    }

    func selectShelfRight(_ id: UUID?) {
        shelfRightID = id
        saveShelf()
    }

    func swapShelfSides() {
        (shelfLeftID, shelfRightID) = (shelfRightID, shelfLeftID)
        saveShelf()
    }

    func moveShelfEntry(_ id: UUID, by offset: Int) {
        guard let index = shelf.firstIndex(where: { $0.id == id }),
              shelf.indices.contains(index + offset) else { return }
        shelf.swapAt(index, index + offset)
        saveShelf()
    }

    func removeShelfEntry(_ id: UUID) {
        let removed = shelf.first { $0.id == id }
        shelf.removeAll { $0.id == id }
        if shelfLeftID == id { shelfLeftID = shelf.first?.id }
        if shelfRightID == id || shelfRightID == shelfLeftID {
            shelfRightID = shelf.first { $0.id != shelfLeftID }?.id
        }
        saveShelf()
        if let removed, removed.isTemporary { discardClipboardIfUnused(removed.url) }
    }

    func saveShelfEntry(_ id: UUID) {
        guard let index = shelf.firstIndex(where: { $0.id == id }), shelf[index].isTemporary else { return }
        let entry = shelf[index]
        let panel = NSSavePanel()
        let suffix = "." + entry.url.pathExtension
        panel.nameFieldStringValue = entry.label.lowercased().hasSuffix(suffix)
            ? entry.label : entry.label + suffix
        if let type = UTType(filenameExtension: entry.url.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != entry.url.standardizedFileURL else {
            errorMessage = "Choose a different location for the saved clipboard source."
            return
        }
        do {
            let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
            if FileManager.default.fileExists(atPath: destination.path) {
                let expected = try Data(contentsOf: destination, options: .mappedIfSafe)
                _ = try SafeTextWrite.replace(at: destination, expected: expected, with: data)
            } else {
                try SafeTextWrite.create(at: destination, data: data)
            }
            shelf[index].path = destination.standardizedFileURL.path
            shelf[index].label = destination.lastPathComponent
            shelf[index].temporary = nil
            saveShelf()
            discardClipboardIfUnused(entry.url)
            noticeMessage = "Saved clipboard source to \(destination.lastPathComponent)."
        } catch {
            errorMessage = "Unable to save clipboard source: \(error.localizedDescription)"
        }
    }

    func renameShelfEntry(_ id: UUID, label: String) {
        guard let index = shelf.firstIndex(where: { $0.id == id }) else { return }
        shelf[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? shelf[index].url.lastPathComponent : label
        saveShelf()
    }

    func compareShelfSelection() {
        guard let left = shelf.first(where: { $0.id == shelfLeftID }),
              let right = shelf.first(where: { $0.id == shelfRightID }),
              left.id != right.id else {
            errorMessage = "Choose two different shelf sources."
            return
        }
        Task { await open(urls: [left.url, right.url]) }
    }

    func openGitFile(_ path: String, from commit: GitCommit, in repository: GitRepository) {
        beginLoading()
        Task {
            defer { endLoading() }
            do {
                let comparison = try await Task.detached(priority: .userInitiated) { () -> TextComparison in
                    let git = GitClient()
                    let before = try commit.parents.first.flatMap {
                        try git.treeItem(in: repository.root, at: $0, path: path)
                    }
                    let after = try git.treeItem(in: repository.root, at: commit.id, path: path)
                    return try compareGitItems(before, after, syntaxHint: path)
                }.value
                let title = "\(path) · \(commit.id.prefix(8))"
                add(title: title, sources: [], content: .text(comparison))
            } catch {
                errorMessage = "Unable to compare \(path): \(error.localizedDescription)"
            }
        }
    }

    func openGitRangeFile(_ change: GitPathChange, from leftID: String, to rightID: String,
                          in root: URL, navigation: GitRangeNavigation? = nil,
                          replacing tabID: UUID? = nil) {
        beginLoading()
        Task {
            defer { endLoading() }
            do {
                let comparison = try await Task.detached(priority: .userInitiated) { () -> TextComparison in
                    let git = GitClient()
                    let before = try git.treeItem(in: root, at: leftID,
                                                  path: change.originalPath ?? change.path)
                    let after = try git.treeItem(in: root, at: rightID, path: change.path)
                    return try compareGitItems(before, after, syntaxHint: change.path,
                                               navigation: navigation)
                }.value
                let title = "\(change.path) · \(leftID.prefix(7))…\(rightID.prefix(7))"
                let content: ComparisonContent = .text(comparison)
                if let tabID {
                    guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
                    tabs[index].title = title
                    tabs[index].content = content
                    tabs[index].contentVersion = UUID()
                    selection = tabID
                } else {
                    add(title: title, sources: [], content: content)
                }
            } catch {
                errorMessage = "Unable to compare \(change.path): \(error.localizedDescription)"
            }
        }
    }

    func navigateGitRange(in tabID: UUID, by offset: Int) {
        guard !isLoading,
              let tab = tabs.first(where: { $0.id == tabID }),
              case .text(let comparison) = tab.content,
              let navigation = comparison.gitRange?.advanced(by: offset) else { return }
        let change = navigation.changes[navigation.index]
        openGitRangeFile(change, from: navigation.fromID, to: navigation.toID,
                         in: navigation.repositoryRoot, navigation: navigation, replacing: tabID)
    }

    func openGitFileRevision(_ revision: GitFileRevision, in repository: GitRepository) {
        beginLoading()
        Task {
            defer { endLoading() }
            do {
                let comparison = try await Task.detached(priority: .userInitiated) { () -> TextComparison in
                    let git = GitClient()
                    let previous = try revision.commit.parents.first.flatMap {
                        try git.treeItem(in: repository.root, at: $0, path: revision.parentPath)
                    }
                    let current = try git.treeItem(in: repository.root, at: revision.commit.id,
                                                   path: revision.path)
                    return try compareGitItems(previous, current, syntaxHint: revision.path)
                }.value
                add(title: "\(revision.path) · \(revision.commit.id.prefix(8))",
                    sources: [], content: .text(comparison))
            } catch {
                errorMessage = "Unable to open file history: \(error.localizedDescription)"
            }
        }
    }

    func openWorkingCopyFile(_ entry: GitStatusEntry, staged: Bool, in repository: GitRepository) {
        beginLoading()
        Task {
            defer { endLoading() }
            do {
                let comparison = try await Task.detached(priority: .userInitiated) { () -> TextComparison in
                    let git = GitClient()
                    let before: GitFileItem?
                    let after: GitFileItem?
                    if staged {
                        let head = try? git.resolveCommit(in: repository.root, ref: "HEAD")
                        before = try head.flatMap {
                            try git.treeItem(in: repository.root, at: $0,
                                             path: entry.originalPath ?? entry.path)
                        }
                        after = try git.indexItem(in: repository.root, path: entry.path)
                    } else {
                        before = try git.indexItem(in: repository.root, path: entry.path)
                        after = try git.workingItem(in: repository.root, path: entry.path)
                    }
                    let notes = !staged && entry.worktreeStatus == "m"
                        ? ["The submodule working tree contains local changes beyond its commit pointer."] : []
                    return try compareGitItems(before, after, syntaxHint: entry.path,
                                               additionalNotes: notes)
                }.value
                let title = "\(entry.path) · \(staged ? "Staged" : "Working Copy")"
                add(title: title, sources: [], content: .text(comparison))
            } catch {
                errorMessage = "Unable to compare \(entry.path): \(error.localizedDescription)"
            }
        }
    }

    func openGitConflict(_ entry: GitStatusEntry, in repository: GitRepository) {
        guard entry.isUnmerged else { return }
        beginLoading()
        Task {
            defer { endLoading() }
            do {
                let content = try await Task.detached(priority: .userInitiated) { () -> ComparisonContent in
                    let git = GitClient()
                    guard let stages = try git.conflictStages(in: repository.root, path: entry.path) else {
                        throw GitError.invalidOutput("The Git conflict has already been resolved")
                    }
                    let output = try git.workingFile(in: repository.root, path: entry.path)
                    let outputURL = repository.root.appendingPathComponent(entry.path)
                    if let base = stages.base, let ours = stages.ours, let theirs = stages.theirs,
                       let snapshots = try? [base, ours, theirs].map(TextSnapshot.init(data:)) {
                        return .merge(TextMergeComparison(
                            sources: [outputURL, outputURL, outputURL],
                            sourceLabels: ["Base (stage 1)", "Ours (stage 2)", "Theirs (stage 3)"],
                            snapshots: snapshots, outputURL: outputURL, expectedOutput: output,
                            isGitConflict: true
                        ))
                    }
                    return .gitWholeFileConflict(GitWholeFileConflictComparison(
                        repositoryRoot: repository.root, path: entry.path,
                        stages: stages, expectedOutput: output
                    ))
                }.value
                add(title: "\(entry.path) · Resolve Conflict", sources: [], content: content)
            } catch {
                errorMessage = "Unable to open Git conflict: \(error.localizedDescription)"
            }
        }
    }

    func openWorktreeHeads(from source: GitWorktree, to target: GitWorktree,
                           in repository: GitRepository) {
        guard let from = source.head, let to = target.head else {
            errorMessage = "Both worktrees need a committed HEAD for this comparison."
            return
        }
        add(title: "\(source.root.lastPathComponent) ↔ \(target.root.lastPathComponent) · HEADs",
            sources: [repository.root],
            content: .repository(RepositoryComparison(repository: repository,
                                                      fromRef: from, toRef: to)))
    }

    func addClipboard() {
        do {
            let pasteboard = NSPasteboard.general
            let data: Data
            let fileExtension: String
            let label: String
            let image = pasteboard.canReadItem(withDataConformingToTypes: NSImage.imageTypes)
            if image, let png = pasteboard.data(forType: .png) {
                data = png
                fileExtension = "png"
                label = "Clipboard image"
            } else if image, let tiff = pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation {
                data = tiff
                fileExtension = "tiff"
                label = "Clipboard image"
            } else if let text = pasteboard.string(forType: .string) {
                data = Data(text.utf8)
                fileExtension = "txt"
                label = "Clipboard text"
            } else {
                errorMessage = "The clipboard does not contain readable text or an image."
                return
            }
            let url = try ManagedSnapshots.createClipboard(data, fileExtension: fileExtension)
            let entry = ShelfEntry(id: UUID(), path: url.path, label: label, temporary: true)
            shelf.append(entry)
            if shelfLeftID == nil { shelfLeftID = entry.id }
            else if shelfRightID == nil { shelfRightID = entry.id }
            saveShelf()
            if fileExtension == "txt" {
                Task { await open(urls: [url], label: label) }
                noticeMessage = "Clipboard text was added to the Source Shelf."
            } else {
                showWelcome()
                noticeMessage = "Clipboard image was added to the Source Shelf. Choose another image to compare."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func open(urls: [URL], label: String? = nil, mergeOutput: URL? = nil) async -> UUID? {
        guard !urls.isEmpty else { return nil }
        if urls.count == 1, urls[0].scheme == "vellograph" {
            await openDeepLink(urls[0])
            return selection
        }
        let interval = loadSignposter.beginInterval("OpenComparison", id: loadSignposter.makeSignpostID())
        defer { loadSignposter.endInterval("OpenComparison", interval) }
        beginLoading()
        defer { endLoading() }
        let candidates = urls.filter { $0.isFileURL }
        guard !candidates.isEmpty else {
            errorMessage = "No local files were provided."
            return nil
        }
        guard candidates.count <= 3, candidates.count == urls.count else {
            errorMessage = "Open one or two sources to compare, or three text files in base, local, remote order to merge."
            return nil
        }
        do {
            let content = try await Task.detached(priority: .userInitiated) { () -> ComparisonContent in
                let first = candidates[0]
                if candidates.count == 3 {
                    let snapshots = try candidates.map { try DocumentTextLoader.load($0).snapshot }
                    let expectedOutput: Data?
                    if let mergeOutput, FileManager.default.fileExists(atPath: mergeOutput.path) {
                        expectedOutput = try Data(contentsOf: mergeOutput, options: .mappedIfSafe)
                    } else {
                        expectedOutput = nil
                    }
                    return .merge(TextMergeComparison(
                        sources: candidates,
                        sourceLabels: candidates.map(\.lastPathComponent),
                        snapshots: snapshots,
                        outputURL: mergeOutput,
                        expectedOutput: expectedOutput,
                        isGitConflict: false
                    ))
                }
                if candidates.count == 1 {
                    if let repository = try? GitClient().repository(at: first) {
                        return .repository(RepositoryComparison(repository: repository,
                                                                fromRef: nil, toRef: nil))
                    }
                    return try loadTextOrMetadata(sources: candidates)
                }
                let second = candidates[1]
                var aDirectory: ObjCBool = false
                var bDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: first.path, isDirectory: &aDirectory)
                FileManager.default.fileExists(atPath: second.path, isDirectory: &bDirectory)
                if aDirectory.boolValue && bDirectory.boolValue {
                    return .folders(FolderComparisonSession(
                        left: first, right: second,
                        entries: try FolderComparison.compare(left: first, right: second)
                    ))
                }
                let imageA = UTType(filenameExtension: first.pathExtension)?.conforms(to: .image) == true
                let imageB = UTType(filenameExtension: second.pathExtension)?.conforms(to: .image) == true
                if imageA && imageB { return .images(first, second) }
                return try loadTextOrMetadata(sources: candidates)
            }.value
            let title = label ?? candidates.map(\.lastPathComponent).joined(separator: candidates.count == 3 ? " · " : " ↔ ")
            let id = add(title: title, sources: candidates, content: content)
            if !candidates.contains(where: isManagedSnapshot) {
                let kind: RecentKind
                if case .repository = content { kind = .repository }
                else { kind = .comparison }
                remember(candidates, title: title, kind: kind)
            }
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func close(_ id: UUID) {
        let removed = tabs.first { $0.id == id }
        tabs.removeAll { $0.id == id }
        if selection == id { selection = tabs.last?.id }
        if let continuation = pendingCommands.removeValue(forKey: id) {
            let status: Int32 = pendingMergeTabs.contains(id) ? 1 : 0
            continuation.resume(returning: IPCResponse(status: status))
        }
        pendingMergeTabs.remove(id)
        saveSession()
        for url in removed?.sources ?? [] where isManagedSnapshot(url) {
            guard !tabs.contains(where: { $0.sources.contains(url) }) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        for url in removed?.sources ?? [] where ManagedSnapshots.containsClipboard(url) {
            discardClipboardIfUnused(url)
        }
    }

    func completeMerge(_ id: UUID, savedAt url: URL) {
        pendingMergeTabs.remove(id)
        if let continuation = pendingCommands.removeValue(forKey: id) {
            continuation.resume(returning: IPCResponse(status: 0, message: url.path))
        }
    }

    func select(_ id: UUID) {
        selection = id
        saveSession()
    }

    func showWelcome() {
        selection = nil
        saveSession()
    }

    func reopen(_ recent: RecentComparison) {
        Task { await open(urls: recent.paths.map { URL(fileURLWithPath: $0) }) }
    }

    func restoreSession() async {
        guard !didRestore else { return }
        didRestore = true
        guard let data = preferences.data(forKey: "savedWorkspace.v1"),
              let saved = try? JSONDecoder().decode(SavedWorkspace.self, from: data) else { return }
        var unavailableCount = 0
        for paths in saved.tabs {
            guard !paths.isEmpty,
                  paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                unavailableCount += 1
                continue
            }
            await open(urls: paths.map { URL(fileURLWithPath: $0) })
        }
        if saved.selectedIndex == -1 {
            selection = nil
        } else if tabs.indices.contains(saved.selectedIndex) {
            selection = tabs[saved.selectedIndex].id
        }
        saveSession()
        if unavailableCount > 0 {
            noticeMessage = "\(unavailableCount) saved \(unavailableCount == 1 ? "comparison was" : "comparisons were") skipped because a source is no longer available."
        }
    }

    @discardableResult
    private func add(title: String, sources: [URL], content: ComparisonContent) -> UUID {
        let tab = ComparisonTab(id: UUID(), title: title, sources: sources, content: content)
        tabs.append(tab)
        selection = tab.id
        saveSession()
        return tab.id
    }

    private func remember(_ urls: [URL], title: String, kind: RecentKind) {
        let paths = urls.map { $0.standardizedFileURL.path }
        recentComparisons.removeAll { $0.paths == paths }
        recentComparisons.insert(RecentComparison(id: UUID(), paths: paths, title: title,
                                                  openedAt: .now, kind: kind), at: 0)
        if recentComparisons.count > 20 { recentComparisons.removeLast(recentComparisons.count - 20) }
        if let data = try? JSONEncoder().encode(recentComparisons) {
            preferences.set(data, forKey: "recentComparisons.v1")
        }
    }

    private func saveSession() {
        let persisted = tabs.filter { !$0.sources.isEmpty && !$0.sources.contains(where: isManagedSnapshot) }
        let selectedIndex = selection.flatMap { selected in
            persisted.firstIndex { $0.id == selected }
        } ?? -1
        let saved = SavedWorkspace(
            tabs: persisted.map { $0.sources.map { $0.standardizedFileURL.path } },
            selectedIndex: selectedIndex
        )
        if let data = try? JSONEncoder().encode(saved) {
            preferences.set(data, forKey: "savedWorkspace.v1")
        }
    }

    private func isManagedSnapshot(_ url: URL) -> Bool {
        ManagedSnapshots.contains(url)
    }

    private func beginLoading() { activeLoads += 1 }

    private func endLoading() { activeLoads -= 1 }

    private func discardClipboardIfUnused(_ url: URL) {
        guard ManagedSnapshots.containsClipboard(url),
              !shelf.contains(where: { $0.url == url }),
              !tabs.contains(where: { $0.sources.contains(url) }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func startIPC() {
        guard !Self.isUITesting else { return }
        guard ipcServer == nil else { return }
        _ = try? ManagedSnapshots.purgeAbandoned(olderThan: .now.addingTimeInterval(-3_600))
        let retained = shelf.map(\.url) + tabs.flatMap(\.sources)
        _ = try? ManagedSnapshots.purgeUnusedClipboard(
            olderThan: .now.addingTimeInterval(-3_600), preserving: retained)
        let server = LocalSocketServer { [weak self] request in
            guard let self else { return IPCResponse(status: 2, message: "Vellograph is closing.") }
            return await self.handleIPC(request)
        }
        do {
            try server.start()
            ipcServer = server
        } catch {
            errorMessage = "The command line connection could not start: \(error.localizedDescription)"
        }
    }

    private func handleIPC(_ request: IPCRequest) async -> IPCResponse {
        NSApp.activate(ignoringOtherApps: true)
        let id: UUID?
        switch request.action {
        case .diff:
            guard (1...2).contains(request.paths.count),
                  request.paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                return IPCResponse(status: 2, message: "Open one or two existing sources.")
            }
            id = await open(urls: request.paths.map { URL(fileURLWithPath: $0) }, label: request.label)
        case .merge:
            guard request.paths.count == 3, let output = request.output,
                  request.paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                return IPCResponse(status: 2, message: "Merge requires a base, local, remote, and output path.")
            }
            id = await open(urls: request.paths.map { URL(fileURLWithPath: $0) },
                            mergeOutput: URL(fileURLWithPath: output))
        case .workingCopy, .changeset:
            guard let path = request.repository,
                  FileManager.default.fileExists(atPath: path) else {
                return IPCResponse(status: 2, message: "The repository path does not exist.")
            }
            do {
                let repository = try await Task.detached(priority: .userInitiated) {
                    try GitClient().repository(at: URL(fileURLWithPath: path))
                }.value
                if request.action == .changeset {
                    guard let from = request.fromRef, let to = request.toRef else {
                        return IPCResponse(status: 2, message: "Choose both Git revisions.")
                    }
                    _ = try await Task.detached(priority: .userInitiated) {
                        let git = GitClient()
                        _ = try git.resolveCommit(in: repository.root, ref: from)
                        _ = try git.resolveCommit(in: repository.root, ref: to)
                    }.value
                    id = add(title: "\(repository.root.lastPathComponent) · \(from)…\(to)",
                             sources: [repository.root], content: .repository(RepositoryComparison(
                                repository: repository, fromRef: from, toRef: to)))
                } else {
                    id = add(title: repository.root.lastPathComponent, sources: [repository.root],
                             content: .repository(RepositoryComparison(repository: repository,
                                                                       fromRef: nil, toRef: nil)))
                }
                remember([repository.root], title: repository.root.lastPathComponent,
                         kind: .repository)
            } catch {
                return IPCResponse(status: 2, message: error.localizedDescription)
            }
        }
        guard let id else {
            return IPCResponse(status: 2, message: errorMessage ?? "The source could not be opened.")
        }
        if request.action == .merge { pendingMergeTabs.insert(id) }
        guard request.wait || request.action == .merge else { return IPCResponse(status: 0) }
        return await withCheckedContinuation { continuation in pendingCommands[id] = continuation }
    }

    private func saveShelf() {
        let state = SavedShelf(entries: shelf, leftID: shelfLeftID, rightID: shelfRightID)
        if let data = try? JSONEncoder().encode(state) {
            preferences.set(data, forKey: "sourceShelf.v1")
        }
    }

    private func openDeepLink(_ url: URL) async {
        do {
            switch try DeepLinkRequest.parse(url) {
            case .compare(let paths):
                guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                    throw DeepLinkError.invalidParameters
                }
                await open(urls: paths.map { URL(fileURLWithPath: $0) })
            case .history(let path):
                let repository = try await Task.detached(priority: .userInitiated) {
                    try GitClient().repository(at: URL(fileURLWithPath: path))
                }.value
                add(title: "\(repository.root.lastPathComponent) · History",
                    sources: [repository.root],
                    content: .repository(RepositoryComparison(repository: repository,
                                                              startInHistory: true)))
            case .changeset(let path, let from, let to):
                let response = await handleIPC(IPCRequest(action: .changeset,
                    repository: path, fromRef: from, toRef: to))
                if response.status != 0 { errorMessage = response.message ?? "Unable to open changeset." }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func loadTextOrMetadata(sources: [URL]) throws -> ComparisonContent {
    do {
        return .text(try TextComparison.load(sources: sources))
    } catch let error as SnapshotError {
        let reason: String
        switch error {
        case .binaryContent: reason = "This file contains binary data. Compare its metadata or exact bytes."
        case .unsupportedEncoding: reason = "The text encoding is unsupported. Compare metadata or exact bytes."
        case .failedToEncode: throw error
        }
        return .metadata(FileMetadataComparison(sources: sources, reason: reason))
    } catch let error as DocumentTextError {
        return .metadata(FileMetadataComparison(sources: sources,
                                                reason: error.localizedDescription))
    }
}

