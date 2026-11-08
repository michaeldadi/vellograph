import AppKit
import SwiftUI
import Sparkle

@main
struct VellographApp: App {
    @State private var workspace = WorkspaceModel()
    @State private var didLoadUITestFixture = false
    private let serviceProvider = VellographServiceProvider()
    private let updater = SPUStandardUpdaterController(
        startingUpdater: ProcessInfo.processInfo.environment["VELLOGRAPH_UI_TESTING"] != "1",
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("Vellograph", id: "workspace") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 900, minHeight: 580)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    Task { await workspace.open(urls: [url]) }
                }
                .task {
                    if ProcessInfo.processInfo.environment["VELLOGRAPH_UI_TESTING"] == "1" {
                        guard !didLoadUITestFixture else { return }
                        didLoadUITestFixture = true
                        let environment = ProcessInfo.processInfo.environment
                        if let paths = environment["VELLOGRAPH_UI_TEST_PATHS"],
                           let data = paths.data(using: .utf8),
                           let values = try? JSONDecoder().decode([String].self, from: data) {
                            let urls = values.map { URL(fileURLWithPath: $0) }
                            if environment["VELLOGRAPH_UI_TEST_SEED_SHELF"] == "1" {
                                workspace.addToShelf(urls)
                            } else {
                                await workspace.open(urls: urls)
                            }
                        }
                        return
                    }
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
            SettingsView(workspace: workspace)
        }
    }
}

