import AppKit
import DiffCore
import FolderCore
import GitCore
import Observation
import UniformTypeIdentifiers

enum ComparisonContent: Sendable {
    case text(TextComparison)
    case merge(TextMergeComparison)
    case folders([FolderDifference])
    case images(URL, URL)
    case repository(GitRepository)
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

    init(sources: [URL], left: TextSnapshot, right: TextSnapshot, diff: DiffResult) {
        self.sources = sources
        self.left = left
        self.right = right
        self.diff = diff
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
}

struct TextMergeComparison: Sendable {
    let sources: [URL]
    let snapshots: [TextSnapshot]
}

struct ComparisonTab: Identifiable {
    let id: UUID
    let title: String
    let sources: [URL]
    var content: ComparisonContent
}

struct RecentComparison: Identifiable, Codable {
    let id: UUID
    let paths: [String]
    let title: String
    let openedAt: Date
}

private struct SavedWorkspace: Codable {
    let tabs: [[String]]
    let selectedIndex: Int
}

@MainActor @Observable
final class WorkspaceModel {
    var tabs: [ComparisonTab] = []
    var selection: UUID?
    var recentComparisons: [RecentComparison] = []
    var isLoading = false
    var errorMessage: String?
    private var didRestore = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "recentComparisons.v1"),
           let recent = try? JSONDecoder().decode([RecentComparison].self, from: data) {
            recentComparisons = recent
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

    func addClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            errorMessage = "The clipboard does not contain text."
            return
        }
        do {
            let left = try TextSnapshot(text: "")
            let right = try TextSnapshot(text: value)
            let diff = try DiffEngine.compare(left.lines, right.lines)
            add(title: "Clipboard", sources: [], content: .text(TextComparison(sources: [], left: left, right: right, diff: diff)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        if urls.count == 1, urls[0].scheme == "vellograph" {
            await openDeepLink(urls[0])
            return
        }
        isLoading = true
        defer { isLoading = false }
        let candidates = urls.filter { $0.isFileURL }
        guard !candidates.isEmpty else {
            errorMessage = "No local files were provided."
            return
        }
        guard candidates.count <= 3, candidates.count == urls.count else {
            errorMessage = "Open one or two sources to compare, or three text files in base, local, remote order to merge."
            return
        }
        do {
            let content = try await Task.detached(priority: .userInitiated) { () -> ComparisonContent in
                let first = candidates[0]
                if candidates.count == 3 {
                    let snapshots = try candidates.map {
                        try TextSnapshot(data: Data(contentsOf: $0, options: .mappedIfSafe))
                    }
                    return .merge(TextMergeComparison(
                        sources: candidates,
                        snapshots: snapshots
                    ))
                }
                if candidates.count == 1 {
                    if let repository = try? GitClient().repository(at: first) {
                        return .repository(repository)
                    }
                    let data = try Data(contentsOf: first, options: .mappedIfSafe)
                    let left = try TextSnapshot(text: "")
                    let right = try TextSnapshot(data: data)
                    let diff = try DiffEngine.compare(left.lines, right.lines)
                    return .text(TextComparison(sources: candidates, left: left, right: right, diff: diff))
                }
                let second = candidates[1]
                var aDirectory: ObjCBool = false
                var bDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: first.path, isDirectory: &aDirectory)
                FileManager.default.fileExists(atPath: second.path, isDirectory: &bDirectory)
                if aDirectory.boolValue && bDirectory.boolValue {
                    return .folders(try FolderComparison.compare(left: first, right: second))
                }
                let imageA = UTType(filenameExtension: first.pathExtension)?.conforms(to: .image) == true
                let imageB = UTType(filenameExtension: second.pathExtension)?.conforms(to: .image) == true
                if imageA && imageB { return .images(first, second) }
                let left = try TextSnapshot(data: Data(contentsOf: first, options: .mappedIfSafe))
                let right = try TextSnapshot(data: Data(contentsOf: second, options: .mappedIfSafe))
                let diff = try DiffEngine.compare(left.lines, right.lines)
                return .text(TextComparison(sources: candidates, left: left, right: right, diff: diff))
            }.value
            let title = candidates.map(\.lastPathComponent).joined(separator: candidates.count == 3 ? " · " : " ↔ ")
            add(title: title, sources: candidates, content: content)
            remember(candidates, title: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if selection == id { selection = tabs.last?.id }
        saveSession()
    }

    func select(_ id: UUID) {
        selection = id
        saveSession()
    }

    func reopen(_ recent: RecentComparison) {
        Task { await open(urls: recent.paths.map { URL(fileURLWithPath: $0) }) }
    }

    func restoreSession() async {
        guard !didRestore else { return }
        didRestore = true
        guard let data = UserDefaults.standard.data(forKey: "savedWorkspace.v1"),
              let saved = try? JSONDecoder().decode(SavedWorkspace.self, from: data) else { return }
        for paths in saved.tabs where !paths.isEmpty && paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
            await open(urls: paths.map { URL(fileURLWithPath: $0) })
        }
        if tabs.indices.contains(saved.selectedIndex) {
            selection = tabs[saved.selectedIndex].id
        }
        saveSession()
    }

    private func add(title: String, sources: [URL], content: ComparisonContent) {
        let tab = ComparisonTab(id: UUID(), title: title, sources: sources, content: content)
        tabs.append(tab)
        selection = tab.id
        saveSession()
    }

    private func remember(_ urls: [URL], title: String) {
        let paths = urls.map { $0.standardizedFileURL.path }
        recentComparisons.removeAll { $0.paths == paths }
        recentComparisons.insert(RecentComparison(id: UUID(), paths: paths, title: title, openedAt: .now), at: 0)
        if recentComparisons.count > 20 { recentComparisons.removeLast(recentComparisons.count - 20) }
        if let data = try? JSONEncoder().encode(recentComparisons) {
            UserDefaults.standard.set(data, forKey: "recentComparisons.v1")
        }
    }

    private func saveSession() {
        let persisted = tabs.filter { !$0.sources.isEmpty }
        let selectedIndex = persisted.firstIndex { $0.id == selection } ?? max(0, persisted.count - 1)
        let saved = SavedWorkspace(
            tabs: persisted.map { $0.sources.map { $0.standardizedFileURL.path } },
            selectedIndex: selectedIndex
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "savedWorkspace.v1")
        }
    }

    private func openDeepLink(_ url: URL) async {
        guard url.host == "compare" || url.host == "diff",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            errorMessage = "Unsupported Vellograph link."
            return
        }
        let paths = (components.queryItems ?? []).filter { $0.name == "file" }.compactMap(\.value)
        await open(urls: paths.map { URL(fileURLWithPath: $0) })
    }
}

