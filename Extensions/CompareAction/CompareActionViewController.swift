import AppKit
import Combine
import DiffCore
import FolderCore
import SwiftUI
import UniformTypeIdentifiers

private enum CompareActionPreview: Sendable {
    case text(String)
    case images(Data, Data)
    case folders(String)
    case unsupported(String)

    static func make(_ left: URL, _ right: URL) throws -> Self {
        let leftAccess = left.startAccessingSecurityScopedResource()
        let rightAccess = right.startAccessingSecurityScopedResource()
        defer {
            if leftAccess { left.stopAccessingSecurityScopedResource() }
            if rightAccess { right.stopAccessingSecurityScopedResource() }
        }
        var leftIsDirectory: ObjCBool = false
        var rightIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: left.path, isDirectory: &leftIsDirectory),
              FileManager.default.fileExists(atPath: right.path, isDirectory: &rightIsDirectory) else {
            return .unsupported("One of the selected items is no longer available.")
        }
        if leftIsDirectory.boolValue && rightIsDirectory.boolValue {
            let differences = try FolderComparison.compare(left: left, right: right)
            let changed = differences.filter { $0.state != .equal }
            let lines = changed.prefix(300).map {
                "\($0.state.rawValue)  \($0.relativePath)"
            }
            let tail = changed.count > 300 ? "\n… \(changed.count - 300) more changed items" : ""
            return .folders("\(changed.count) changed items\n\n" + lines.joined(separator: "\n") + tail)
        }
        guard !leftIsDirectory.boolValue && !rightIsDirectory.boolValue else {
            return .unsupported("Select two files or two folders of the same kind.")
        }
        let leftIsImage = UTType(filenameExtension: left.pathExtension)?.conforms(to: .image) == true
        let rightIsImage = UTType(filenameExtension: right.pathExtension)?.conforms(to: .image) == true
        if leftIsImage && rightIsImage {
            let a = try boundedData(left, maxBytes: 25_000_000)
            let b = try boundedData(right, maxBytes: 25_000_000)
            return .images(a, b)
        }
        if leftIsImage || rightIsImage {
            return .unsupported("Select two images to view them together.")
        }
        let a = try TextSnapshot(data: boundedData(left, maxBytes: 5_000_000))
        let b = try TextSnapshot(data: boundedData(right, maxBytes: 5_000_000))
        let diff = try DiffEngine.compare(a.lines, b.lines)
        let patch = UnifiedPatch.generate(oldLabel: left.lastPathComponent,
                                          newLabel: right.lastPathComponent,
                                          old: a.lines, new: b.lines, diff: diff)
        let visible = String(patch.prefix(120_000))
        return .text("\(diff.hunks.count) changes\n\n" + visible +
                     (patch.count > 120_000 ? "\n… Preview truncated. Open the full app for all changes." : ""))
    }

    fileprivate static func boundedData(_ url: URL, maxBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= maxBytes else {
            throw CompareActionError.fileTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(size)
        while let chunk = try handle.read(upToCount: min(262_144, maxBytes - data.count + 1)),
              !chunk.isEmpty {
            guard chunk.count <= maxBytes - data.count else {
                throw CompareActionError.fileTooLarge
            }
            data.append(chunk)
        }
        return data
    }
}

private enum CompareActionError: LocalizedError {
    case fileTooLarge
    case missingHostItem

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "This item is too large for the quick preview. Open it in Vellograph instead."
        case .missingHostItem:
            "The host app could not provide the selected item."
        }
    }
}

@MainActor private final class CompareActionState: ObservableObject {
    @Published var selected: [URL] = []
    @Published var preview: CompareActionPreview?
    @Published var message = "Loading selected items…"
    @Published var isLoading = true

    private var providers: [NSItemProvider] = []
    private var providerIndex = 0
    private var temporarySources: [URL] = []
    private var finished = false

    func load(_ context: NSExtensionContext?) {
        providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= 2 else {
            message = "Choose one or two local files or folders."
            isLoading = false
            return
        }
        loadNextProvider()
    }

    func chooseSecond(_ url: URL) {
        guard selected.count == 1, url.isFileURL else { return }
        selected.append(url)
        compareSelected()
    }

    func cleanup() {
        finished = true
        for url in temporarySources {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporarySources.removeAll()
    }

    private func loadNextProvider() {
        guard providerIndex < providers.count else {
            isLoading = false
            if selected.count == 2 { compareSelected() }
            else { message = "Choose a second local item to compare." }
            return
        }
        let provider = providers[providerIndex]
        providerIndex += 1
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] value, error in
                let failure = error?.localizedDescription
                Task { @MainActor [weak self] in
                    self?.accept(value, failure: failure)
                }
            }
        } else if let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .text) || type.conforms(to: .data)
        }) {
            let suggestedName = provider.suggestedName ?? "Finder Item \(providerIndex)"
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] source, error in
                let local: URL?
                let failure: String?
                do {
                    guard let source else {
                        throw error ?? CompareActionError.missingHostItem
                    }
                    local = try Self.copyHostItem(source, typeIdentifier: typeIdentifier,
                                                  suggestedName: suggestedName)
                    failure = nil
                } catch {
                    local = nil
                    failure = error.localizedDescription
                }
                Task { @MainActor [weak self] in
                    self?.accept(local, failure: failure, temporary: true)
                }
            }
        } else {
            message = "The host app did not provide a local file or supported content."
            isLoading = false
        }
    }

    nonisolated private static func copyHostItem(
        _ source: URL, typeIdentifier: String, suggestedName: String?
    ) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw CompareActionError.fileTooLarge
        }
        let data = try CompareActionPreview.boundedData(source, maxBytes: 25_000_000)
        let type = UTType(typeIdentifier)
        let fallbackExtension = type?.preferredFilenameExtension ?? source.pathExtension
        let candidate = URL(fileURLWithPath: suggestedName ?? "Selected Item").lastPathComponent
        let filename = candidate.isEmpty || candidate == "." || candidate == ".."
            ? "Selected Item" : candidate
        let fullName = URL(fileURLWithPath: filename).pathExtension.isEmpty && !fallbackExtension.isEmpty
            ? filename + "." + fallbackExtension : filename
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VellographAction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let destination = directory.appendingPathComponent(fullName)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: destination.path)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func accept(_ url: URL?, failure: String?, temporary: Bool = false) {
        if finished {
            if temporary, let url {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            return
        }
        guard let url, url.isFileURL else {
            message = failure ?? "The selected item is not a local file."
            isLoading = false
            return
        }
        if temporary { temporarySources.append(url) }
        selected.append(url)
        loadNextProvider()
    }

    private func compareSelected() {
        guard selected.count == 2 else { return }
        isLoading = true
        message = "Comparing local items…"
        let left = selected[0]
        let right = selected[1]
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CompareActionPreview.make(left, right)
                }.value
                preview = result
                message = ""
            } catch {
                preview = nil
                message = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct CompareActionView: View {
    @ObservedObject var state: CompareActionState
    let chooseSecond: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Compare with Vellograph").font(.title3.bold())
                Spacer()
                Button("Done", action: done)
            }
            Text(state.selected.map(\.lastPathComponent).joined(separator: " ↔ "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if state.isLoading {
                ProgressView(state.message)
            } else if state.selected.count == 1 {
                Text(state.message)
                Button("Choose Second Item…", action: chooseSecond)
            } else if let preview = state.preview {
                switch preview {
                case .text(let patch), .folders(let patch):
                    ScrollView([.vertical, .horizontal]) {
                        Text(patch)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                case .images(let left, let right):
                    HStack(spacing: 8) {
                        imageView(left, label: "A")
                        imageView(right, label: "B")
                    }
                case .unsupported(let reason):
                    ContentUnavailableView(reason, systemImage: "doc.questionmark")
                }
            } else {
                ContentUnavailableView(state.message, systemImage: "exclamationmark.triangle")
            }
            Spacer(minLength: 0)
            Text("Read-only quick preview. Finder Services opens the full Vellograph workspace.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
    }

    private func imageView(_ data: Data, label: String) -> some View {
        VStack {
            Text(label).font(.headline)
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("Cannot decode image", systemImage: "photo.badge.exclamationmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@objc(CompareActionViewController)
@MainActor final class CompareActionViewController: NSViewController {
    private let state = CompareActionState()
    private var started = false

    override func loadView() {
        view = NSHostingView(rootView: CompareActionView(
            state: state,
            chooseSecond: { [weak self] in self?.chooseSecond() },
            done: { [weak self] in
                self?.state.cleanup()
                self?.extensionContext?.completeRequest(returningItems: [])
            }
        ))
        preferredContentSize = NSSize(width: 760, height: 540)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        state.load(extensionContext)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        state.cleanup()
    }

    private func chooseSecond() {
        guard let window = view.window else {
            state.message = "The file chooser is unavailable in this host. Select two items before sharing."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Share hosts are modal. A modeless panel can appear behind the host's
        // dialog, leaving the button looking inert.
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.state.chooseSecond(url) }
        }
    }
}
