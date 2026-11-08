import AppKit
import SwiftUI
import Sparkle

@main
struct VellographApp: App {
    @State private var workspace = WorkspaceModel()
    private let serviceProvider = VellographServiceProvider()
    private let updater = SPUStandardUpdaterController(
        startingUpdater: ProcessInfo.processInfo.environment["VELLOGRAPH_UI_TESTING"] != "1",
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("Vellograph") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 900, minHeight: 580)
                .onOpenURL { url in
                    Task { await workspace.open(urls: [url]) }
                }
                .task {
                    guard ProcessInfo.processInfo.environment["VELLOGRAPH_UI_TESTING"] != "1" else { return }
                    serviceProvider.workspace = workspace
                    NSApp.servicesProvider = serviceProvider
                    ShortcutsInbox.shared.connect(workspace)
                    MenuBarController.shared.connect(workspace)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { workspace.chooseFiles() }
                    .keyboardShortcut("o")
                Button("Add Clipboard to Shelf") { workspace.addClipboard() }
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

