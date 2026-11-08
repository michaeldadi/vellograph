import SwiftUI
import Sparkle

@main
struct MacDiffStudioApp: App {
    @State private var workspace = WorkspaceModel()
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("Mac Diff Studio") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 900, minHeight: 580)
                .onOpenURL { url in
                    Task { await workspace.open(urls: [url]) }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { workspace.chooseFiles() }
                    .keyboardShortcut("o")
                Button("Compare Clipboard") { workspace.addClipboard() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.updater.checkForUpdates() }
            }
        }
        Settings {
            SettingsView()
        }
    }
}

