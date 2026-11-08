import AppKit
import DiffCore
import FolderCore
import GitCore
import Observation
import UniformTypeIdentifiers

enum ComparisonContent: Sendable {
    case text(TextComparison)
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
}

struct ComparisonTab: Identifiable {
    let id: UUID
    let title: String
    var content: ComparisonContent
}

@MainActor @Observable
final class WorkspaceModel {
    var tabs: [ComparisonTab] = []
    var selection: UUID?
    var isLoading = false
    var errorMessage: String?

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
            add(title: "Clipboard", content: .text(TextComparison(sources: [], left: left, right: right, diff: diff)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        if urls.count == 1, urls[0].scheme == "macdiffstudio" {
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
        do {
            let content = try await Task.detached(priority: .userInitiated) { () -> ComparisonContent in
                let first = candidates[0]
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
            let title = candidates.prefix(2).map(\.lastPathComponent).joined(separator: " ↔ ")
            add(title: title, content: content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if selection == id { selection = tabs.last?.id }
    }

    private func add(title: String, content: ComparisonContent) {
        let tab = ComparisonTab(id: UUID(), title: title, content: content)
        tabs.append(tab)
        selection = tab.id
    }

    private func openDeepLink(_ url: URL) async {
        guard url.host == "compare" || url.host == "diff",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            errorMessage = "Unsupported Mac Diff Studio link."
            return
        }
        let paths = (components.queryItems ?? []).filter { $0.name == "file" }.compactMap(\.value)
        await open(urls: paths.map { URL(fileURLWithPath: $0) })
    }
}

