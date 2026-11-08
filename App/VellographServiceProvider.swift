import AppKit

/// Finder and other Services hosts send selected file URLs on a dedicated
/// pasteboard. The provider only reads local URLs and leaves the pasteboard
/// untouched.
@MainActor final class VellographServiceProvider: NSObject {
    weak var workspace: WorkspaceModel?

    @objc(compareFiles:userData:error:)
    func compareFiles(_ pasteboard: NSPasteboard, userData: String?,
                      error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard (1...2).contains(urls.count), urls.allSatisfy(\.isFileURL) else {
            error.pointee = "Select one or two local files or folders." as NSString
            return
        }
        guard let workspace else {
            error.pointee = "Vellograph is still starting. Try again." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { await workspace.open(urls: urls) }
    }
}
