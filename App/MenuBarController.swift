import AppKit
import SwiftUI

/// Keeps the optional status item outside the main SwiftUI scene graph. Its
/// popover shares the workspace loader and exists only while the app runs.
@MainActor final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var workspace: WorkspaceModel?

    func connect(_ workspace: WorkspaceModel) {
        self.workspace = workspace
        setVisible(UserDefaults.standard.bool(forKey: "showMenuBarHelper.v1"))
    }

    func setVisible(_ visible: Bool) {
        guard workspace != nil else { return }
        if visible {
            guard statusItem == nil, let workspace else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: "Vellograph")
            item.button?.toolTip = "Vellograph drop helper"
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 330, height: 230)
            popover.contentViewController = NSHostingController(rootView: MenuBarDropView(workspace: workspace))
            self.popover = popover
            statusItem = item
        } else if let statusItem {
            popover?.close()
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            popover = nil
        }
    }

    func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard statusItem?.button != nil, let popover else { return }
        if popover.isShown {
            popover.close()
        } else {
            showPopover()
        }
    }
}
