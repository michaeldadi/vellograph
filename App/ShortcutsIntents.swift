import AppIntents
import Foundation

/// Routes Shortcuts requests through the same workspace loader as the app's
/// other entry points. An intent may arrive while the first window is opening.
@MainActor final class ShortcutsInbox {
    static let shared = ShortcutsInbox()
    private weak var workspace: WorkspaceModel?
    private var pending: [[URL]] = []

    func connect(_ workspace: WorkspaceModel) {
        self.workspace = workspace
        let requests = pending
        pending.removeAll()
        for urls in requests {
            Task { await workspace.open(urls: urls) }
        }
    }

    func submit(_ urls: [URL]) {
        if let workspace {
            Task { await workspace.open(urls: urls) }
        } else {
            pending.append(urls)
        }
    }
}

struct CompareLocalFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compare Local Files"
    static let description = IntentDescription("Open one or two local files or folders in Vellograph.")
    static let openAppWhenRun = true

    @Parameter(title: "First File or Folder") var first: URL
    @Parameter(title: "Second File or Folder") var second: URL?

    @MainActor
    func perform() async throws -> some IntentResult {
        let urls = [first, second].compactMap { $0 }
        guard urls.allSatisfy(\.isFileURL),
              urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ShortcutsInputError.localFileRequired
        }
        ShortcutsInbox.shared.submit(urls)
        return .result()
    }
}

private enum ShortcutsInputError: LocalizedError {
    case localFileRequired

    var errorDescription: String? {
        "Choose local files or folders that still exist."
    }
}

struct VellographShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CompareLocalFilesIntent(),
                    phrases: ["Compare local files in \(.applicationName)"],
                    shortTitle: "Compare Files",
                    systemImageName: "square.split.2x1")
    }
}
