import AppKit
import DiffCore
import FolderCore
import GitCore
import SwiftUI

struct WorkspaceView: View {
    private enum TabScrollTarget: Hashable {
        case welcome
        case tab(UUID)
    }

    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty { tabStrip }
            if let tab = workspace.selectedTab {
                if !tab.sources.isEmpty { SourcePathBar(sources: tab.sources) }
                content(for: tab).id(tab.contentVersion)
            } else {
                welcome
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Files", systemImage: "folder.badge.plus") { workspace.chooseFiles() }
                Button("Add to Shelf", systemImage: "square.stack.3d.up.badge.a") {
                    workspace.chooseShelfSources()
                    workspace.showWelcome()
                }
                Button("Add Clipboard", systemImage: "doc.on.clipboard") { workspace.addClipboard() }
            }
        }
        .overlay(alignment: .bottom) {
            if workspace.isLoading {
                ProgressView("Comparing…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
        }
        .alert("Unable to Open", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            workspace.addToShelf(urls)
            if urls.count <= 3 { Task { await workspace.open(urls: urls) } }
            else { workspace.showWelcome() }
            return true
        }
        .task {
            await workspace.restoreSession()
            workspace.startIPC()
        }
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    Button {
                        workspace.showWelcome()
                    } label: {
                        Image(systemName: "house")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show welcome")
                    .padding(.horizontal, 10)
                    .id(TabScrollTarget.welcome)
                    ForEach(workspace.tabs) { tab in
                        HStack(spacing: 8) {
                            Text(tab.title).lineLimit(1)
                            Button {
                                workspace.close(tab.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close \(tab.title)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(workspace.selection == tab.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { workspace.select(tab.id) }
                        .id(TabScrollTarget.tab(tab.id))
                    }
                }
                .padding(6)
            }
            .accessibilityIdentifier("Comparison tabs")
            .task(id: workspace.selection) {
                // Newly appended tabs need a layout pass before scrollTo can find them.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                if let selection = workspace.selection {
                    proxy.scrollTo(TabScrollTarget.tab(selection), anchor: .trailing)
                } else {
                    proxy.scrollTo(TabScrollTarget.welcome, anchor: .leading)
                }
            }
        }
        .background(.bar)
    }

    @ViewBuilder private func content(for tab: ComparisonTab) -> some View {
        switch tab.content {
        case .text(let comparison):
            TextComparisonView(comparison: comparison, workspace: workspace, tabID: tab.id)
        case .merge(let comparison):
            MergeComparisonView(comparison: comparison) { url in
                workspace.completeMerge(tab.id, savedAt: url)
            }
        case .gitWholeFileConflict(let comparison):
            GitWholeFileConflictView(comparison: comparison) { url in
                workspace.completeMerge(tab.id, savedAt: url)
            }
        case .folders(let session): FolderComparisonView(session: session, workspace: workspace)
        case .images(let left, let right): ImageComparisonView(left: left, right: right)
        case .metadata(let comparison): MetadataComparisonView(comparison: comparison)
        case .repository(let session): RepositoryView(session: session, workspace: workspace)
        case .message(let message): ContentUnavailableView(message, systemImage: "doc.questionmark")
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 18) {
            ContentUnavailableView {
                Label("Vellograph", systemImage: "square.split.2x1")
            } description: {
                Text("Open two sources to compare or three text files in base, local, remote order to merge.")
            } actions: {
                HStack {
                    Button("Open Files or Folders…") { workspace.chooseFiles() }
                        .buttonStyle(.borderedProminent)
                    Button("Add to Shelf…") { workspace.chooseShelfSources() }
                }
            }
            shelfView
            if let notice = workspace.noticeMessage {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 760, alignment: .leading)
            }
            if workspace.recentComparisons.contains(where: { $0.kind == .repository }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Repositories").font(.headline)
                    ForEach(workspace.recentComparisons.filter { $0.kind == .repository }) { recent in
                        Button { workspace.reopen(recent) } label: {
                            Label(recent.title, systemImage: "arrow.triangle.branch")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(recent.paths.joined(separator: " · "))
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
            }
            if workspace.recentComparisons.contains(where: { $0.kind != .repository }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Comparisons")
                        .font(.headline)
                    ForEach(workspace.recentComparisons.filter { $0.kind != .repository }) { recent in
                        Button {
                            workspace.reopen(recent)
                        } label: {
                            Label(recent.title, systemImage: recent.paths.count == 1 ? "doc" : "square.split.2x1")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(recent.paths.joined(separator: " · "))
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
            }
            }
        .padding(24)
        .frame(maxWidth: .infinity)
        }
    }

    private var shelfView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Source Shelf").font(.headline)
                Spacer()
                Button("Add…") { workspace.chooseShelfSources() }
                Button("Swap A/B", systemImage: "arrow.left.arrow.right") { workspace.swapShelfSides() }
                    .disabled(workspace.shelf.count < 2)
                Button("Compare A/B") { workspace.compareShelfSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.shelfLeftID == nil || workspace.shelfRightID == nil ||
                              workspace.shelfLeftID == workspace.shelfRightID)
            }
            if workspace.shelf.isEmpty {
                Text("Add files or folders, then choose A and B. Sources stay in the order shown here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(workspace.shelf.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 6) {
                        Button("A") { workspace.selectShelfLeft(entry.id) }
                            .buttonStyle(.bordered)
                            .tint(workspace.shelfLeftID == entry.id ? .accentColor : .secondary)
                            .accessibilityLabel("Select \(entry.label) as A")
                        Button("B") { workspace.selectShelfRight(entry.id) }
                            .buttonStyle(.bordered)
                            .tint(workspace.shelfRightID == entry.id ? .accentColor : .secondary)
                            .accessibilityLabel("Select \(entry.label) as B")
                        TextField("Source label", text: Binding(
                            get: { workspace.shelf.first(where: { $0.id == entry.id })?.label ?? entry.label },
                            set: { workspace.renameShelfEntry(entry.id, label: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .help(entry.path)
                        Spacer(minLength: 4)
                        if entry.isTemporary {
                            Button("Save…") { workspace.saveShelfEntry(entry.id) }
                                .help("Save this clipboard source as a file")
                        }
                        Button("Move Up", systemImage: "chevron.up") { workspace.moveShelfEntry(entry.id, by: -1) }
                            .disabled(index == 0)
                            .labelStyle(.iconOnly)
                        Button("Move Down", systemImage: "chevron.down") { workspace.moveShelfEntry(entry.id, by: 1) }
                            .disabled(index == workspace.shelf.count - 1)
                            .labelStyle(.iconOnly)
                        Button("Remove", systemImage: "xmark") { workspace.removeShelfEntry(entry.id) }
                            .labelStyle(.iconOnly)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SourcePathBar: View {
    let sources: [URL]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(sources.enumerated()), id: \.offset) { index, url in
                Menu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                    }
                    Button("Open with Default App") { NSWorkspace.shared.open(url) }
                    Button("Open Location in Terminal") {
                        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                        NSWorkspace.shared.open([directory], withApplicationAt: terminal,
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Label("\(index == 0 ? "A" : index == 1 ? "B" : "C"): \(url.lastPathComponent)",
                          systemImage: "folder")
                        .lineLimit(1)
                }
                .help(url.path)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct SettingsView: View {
    let workspace: WorkspaceModel
    @AppStorage("showMenuBarHelper.v1") private var showMenuBarHelper = false
    @State private var showingDropHelper = false

    var body: some View {
        Form {
            Toggle("Show menu bar drop helper", isOn: $showMenuBarHelper)
                .onChange(of: showMenuBarHelper) { _, visible in
                    MenuBarController.shared.setVisible(visible)
                }
            if showMenuBarHelper {
                Button("Open Drop Helper") {
                    showingDropHelper = true
                }
                .popover(isPresented: $showingDropHelper) {
                    MenuBarDropView(workspace: workspace)
                }
            }
            LabeledContent("Minimum macOS", value: "27")
            LabeledContent("Privacy", value: "Comparisons stay on this Mac")
        }
        .padding()
        .frame(width: 420)
    }
}

