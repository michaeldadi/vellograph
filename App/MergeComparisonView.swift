import AppKit
import DiffCore
import SwiftUI

struct MergeComparisonView: View {
    let comparison: TextMergeComparison
    @State private var roleIndices = [0, 1, 2]
    @State private var rolesConfirmed = false
    @State private var isComputing = false
    @State private var mergeResult: MergeResult?
    @State private var choices: [Int: MergeChoice] = [:]
    @State private var output: String?
    @State private var errorMessage: String?
    @State private var savedURL: URL?
    @State private var showingChangeChoices = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Three-way merge", systemImage: "arrow.triangle.merge")
                    .font(.headline)
                Spacer()
                if let mergeResult {
                    Text("\(choices.count) of \(mergeResult.conflicts.count) conflicts resolved")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                sourcePicker("Base", role: 0)
                sourcePicker("Local", role: 1)
                sourcePicker("Remote", role: 2)
            }
            .padding(12)
            Divider()
            if isComputing {
                ProgressView("Comparing three sources…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !rolesConfirmed {
                ContentUnavailableView("Assign source roles", systemImage: "arrow.triangle.branch", description: Text("Choose which file is the common base, your local version, and the remote version. Then confirm the roles."))
            } else if let mergeResult, mergeResult.conflicts.isEmpty {
                ContentUnavailableView("No conflicts", systemImage: "checkmark.circle", description: Text("The changes can be merged automatically."))
            } else if let mergeResult {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(mergeResult.conflicts) { conflict in
                            conflictView(conflict)
                        }
                    }
                    .padding(14)
                }
            }
            Divider()
            if let output {
                TextEditor(text: Binding(
                    get: { output },
                    set: { self.output = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Merged output")
                .frame(minHeight: 170)
                .padding(8)
            }
            HStack {
                if output != nil {
                    Text("Review and edit the output before saving.")
                        .foregroundStyle(.secondary)
                }
                if let savedURL {
                    Text("Saved \(savedURL.lastPathComponent)")
                        .foregroundStyle(.secondary)
                        .help(savedURL.path)
                }
                Spacer()
                if !rolesConfirmed {
                    Button("Confirm Roles") { confirmRoles() }
                        .disabled(isComputing)
                } else if output == nil {
                    Button("Change Roles") {
                        rolesConfirmed = false
                        mergeResult = nil
                        choices = [:]
                    }
                    Button("Build Output") { buildOutput() }
                        .disabled(mergeResult == nil || choices.count != mergeResult?.conflicts.count)
                } else {
                    if mergeResult?.conflicts.isEmpty == false {
                        Button("Change Choices…") { showingChangeChoices = true }
                    }
                    Button("Save As…") { saveOutput() }
                        .keyboardShortcut("s", modifiers: [.command])
                }
            }
            .padding(12)
        }
        .alert("Merge Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Discard edited output and change choices?", isPresented: $showingChangeChoices) {
            Button("Discard Output", role: .destructive) {
                output = nil
                savedURL = nil
            }
            Button("Keep Output", role: .cancel) {}
        }
    }

    private func sourcePicker(_ title: String, role: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: Binding(
                get: { roleIndices[role] },
                set: { selected in
                    if let other = roleIndices.firstIndex(of: selected) {
                        roleIndices[other] = roleIndices[role]
                    }
                    roleIndices[role] = selected
                }
            )) {
                ForEach(comparison.sources.indices, id: \.self) { index in
                    Text(comparison.sources[index].lastPathComponent).tag(index)
                }
            }
            .disabled(rolesConfirmed || isComputing || output != nil)
            Text(comparison.sources[roleIndices[role]].path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(comparison.sources[roleIndices[role]].path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmRoles() {
        let selected = roleIndices
        let snapshots = comparison.snapshots
        isComputing = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try MergeEngine.merge(
                        base: snapshots[selected[0]].lines,
                        ours: snapshots[selected[1]].lines,
                        theirs: snapshots[selected[2]].lines
                    )
                }.value
                guard roleIndices == selected else { return }
                mergeResult = result
                rolesConfirmed = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isComputing = false
        }
    }

    private func conflictView(_ conflict: MergeConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conflict.baseRange.isEmpty
                 ? "Conflict \(conflict.id + 1) · after base line \(conflict.baseRange.lowerBound)"
                 : "Conflict \(conflict.id + 1) · base lines \(conflict.baseRange.lowerBound + 1)–\(conflict.baseRange.upperBound)")
                .font(.headline)
            HStack(alignment: .top, spacing: 10) {
                choicePane("Local", lines: conflict.ours, choice: .ours, conflict: conflict)
                choicePane("Remote", lines: conflict.theirs, choice: .theirs, conflict: conflict)
            }
            HStack {
                choiceButton("Use Both", choice: .both, conflict: conflict)
                choiceButton("Use Neither", choice: .neither, conflict: conflict)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func choicePane(_ title: String, lines: [TextLine], choice: MergeChoice, conflict: MergeConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(lines.map(\.fullText).joined().isEmpty ? "(empty)" : lines.map(\.fullText).joined())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
            choiceButton("Use \(title)", choice: choice, conflict: conflict)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceButton(_ title: String, choice: MergeChoice, conflict: MergeConflict) -> some View {
        Button {
            choices[conflict.id] = choice
        } label: {
            Label(title, systemImage: choices[conflict.id] == choice ? "checkmark.circle.fill" : "circle")
        }
        .disabled(output != nil)
    }

    private func buildOutput() {
        guard let mergeResult else { return }
        do {
            output = try mergeResult.lines(choices: choices).map(\.fullText).joined()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveOutput() {
        guard let output else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = comparison.sources[roleIndices[1]].lastPathComponent + ".merged"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if comparison.sources.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            errorMessage = "Choose a separate output file to preserve the three inputs."
            return
        }
        do {
            let snapshot = try TextSnapshot(
                text: output,
                encoding: comparison.snapshots[roleIndices[0]].encoding,
                hasByteOrderMark: comparison.snapshots[roleIndices[0]].hasByteOrderMark
            )
            try snapshot.originalData.write(to: url, options: .atomic)
            savedURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
