import AppKit
import DiffCore
import FolderCore
import GitCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty { tabStrip }
            if let tab = workspace.selectedTab {
                content(for: tab)
            } else {
                welcome
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Files", systemImage: "folder.badge.plus") { workspace.chooseFiles() }
                Button("Compare Clipboard", systemImage: "doc.on.clipboard") { workspace.addClipboard() }
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
            Task { await workspace.open(urls: urls) }
            return true
        }
        .task { await workspace.restoreSession() }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
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
                }
            }.padding(6)
        }
        .background(.bar)
    }

    @ViewBuilder private func content(for tab: ComparisonTab) -> some View {
        switch tab.content {
        case .text(let comparison): TextComparisonView(comparison: comparison)
        case .merge(let comparison): MergeComparisonView(comparison: comparison)
        case .folders(let entries): FolderComparisonView(entries: entries)
        case .images(let left, let right): ImageComparisonView(left: left, right: right)
        case .repository(let repository): RepositoryView(repository: repository, workspace: workspace)
        case .message(let message): ContentUnavailableView(message, systemImage: "doc.questionmark")
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label("Vellograph", systemImage: "square.split.2x1")
            } description: {
                Text("Open two sources to compare or three text files in base, local, remote order to merge.")
            } actions: {
                Button("Open Files or Folders…") { workspace.chooseFiles() }
                    .buttonStyle(.borderedProminent)
            }
            if !workspace.recentComparisons.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Comparisons")
                        .font(.headline)
                    ForEach(workspace.recentComparisons) { recent in
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Minimum macOS", value: "27")
            LabeledContent("Privacy", value: "Comparisons stay on this Mac")
        }
        .padding()
        .frame(width: 420)
    }
}

