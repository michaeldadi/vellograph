import AppKit
import SwiftUI

/// A small, optional drop surface while Vellograph is running. Single-item
/// drops are held in memory until the second item arrives or the user clears it.
struct MenuBarDropView: View {
    let workspace: WorkspaceModel
    @State private var first: URL?
    @State private var isTargeted = false
    @State private var dropError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.split.2x1")
                    .font(.title2)
                Text("Vellograph")
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: 8) {
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.largeTitle)
                Text(first == nil ? "Drop one or two local items" : "Drop the second item")
                    .font(.subheadline.weight(.medium))
                Text(first == nil
                     ? "Files, folders, and images stay on this Mac."
                     : "A: \(first?.lastPathComponent ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(isTargeted ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2))
            .accessibilityLabel(first == nil ? "Drop files to compare"
                                : "Drop B to compare with \(first?.lastPathComponent ?? "")")
            .dropDestination(for: URL.self) { urls, _ in
                accept(urls)
            } isTargeted: { isTargeted = $0 }

            HStack {
                Button("Open Files…") { workspace.chooseFiles() }
                if first != nil {
                    Button("Clear A") { first = nil }
                }
                Spacer()
                Button("Show App") { NSApp.activate(ignoringOtherApps: true) }
            }
            if let dropError {
                Text(dropError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private func accept(_ urls: [URL]) -> Bool {
        guard (1...2).contains(urls.count),
              urls.allSatisfy(\.isFileURL),
              urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            dropError = "Drop one or two local files or folders."
            return false
        }
        dropError = nil
        if urls.count == 2 {
            first = nil
            Task { await workspace.open(urls: urls) }
        } else if let previous = first {
            first = nil
            Task { await workspace.open(urls: [previous, urls[0]]) }
        } else {
            first = urls[0]
        }
        return true
    }
}
