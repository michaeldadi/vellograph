import AppKit
import DiffCore
import SwiftUI

struct TextResolutionView: View {
    let comparison: TextComparison
    let onDone: () -> Void

    @State private var choices: [Int: TextChangeChoice] = [:]
    @State private var choiceHistory: [[Int: TextChangeChoice]] = []
    @State private var output: String?
    @State private var encodingSide = 1
    @State private var savedURL: URL?
    @State private var recoveryURL: URL?
    @State private var errorMessage: String?
    @State private var confirmDiscard = false

    private var canReplaceSources: Bool {
        comparison.sources.count == 2 && comparison.extractionNotes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Resolve Text Changes").font(.title2.bold())
                Spacer()
                Text("\(choices.count) of \(comparison.diff.hunks.count) chosen")
                    .foregroundStyle(.secondary)
            }
            Text("Choose A, B, both, or neither for each changed region. Review the combined output before writing a file.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Use A for All") { assignAll(.left) }.disabled(output != nil)
                Button("Use B for All") { assignAll(.right) }.disabled(output != nil)
                Button("Undo Choice", systemImage: "arrow.uturn.backward") {
                    if let previous = choiceHistory.popLast() { choices = previous }
                }
                .disabled(choiceHistory.isEmpty || output != nil)
                .keyboardShortcut("z", modifiers: [.command])
                Spacer()
            }
            if output == nil && !comparison.diff.hunks.isEmpty {
                HStack {
                    Text("Next change: \((nextUnresolvedHunkID ?? 0) + 1)")
                        .foregroundStyle(.secondary)
                    Button("A") { chooseNext(.left) }
                        .keyboardShortcut("1", modifiers: [.command])
                        .accessibilityLabel("Use A for next unresolved change")
                    Button("B") { chooseNext(.right) }
                        .keyboardShortcut("2", modifiers: [.command])
                        .accessibilityLabel("Use B for next unresolved change")
                    Button("Both") { chooseNext(.both) }
                        .keyboardShortcut("3", modifiers: [.command])
                        .accessibilityLabel("Use Both for next unresolved change")
                    Button("Neither") { chooseNext(.neither) }
                        .keyboardShortcut("4", modifiers: [.command])
                        .accessibilityLabel("Use Neither for next unresolved change")
                    Spacer()
                    Text("⌘1–4 · ⌘⇧↩ Build")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .disabled(nextUnresolvedHunkID == nil)
            }
            List(comparison.diff.hunks) { hunk in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Change \(hunk.id + 1) · A lines \(rangeName(hunk.oldRange)) · B lines \(rangeName(hunk.newRange))")
                        .font(.headline)
                    HStack(alignment: .top, spacing: 10) {
                        preview("A", lines: Array(comparison.left.lines[hunk.oldRange]))
                        preview("B", lines: Array(comparison.right.lines[hunk.newRange]))
                    }
                    HStack {
                        ForEach(TextChangeChoice.allCases, id: \.self) { choice in
                            Button {
                                choiceHistory.append(choices)
                                choices[hunk.id] = choice
                            } label: {
                                Label(choice.rawValue,
                                      systemImage: choices[hunk.id] == choice ? "checkmark.circle.fill" : "circle")
                            }
                            .disabled(output != nil)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(minHeight: 230)
            if output != nil {
                Divider()
                HStack {
                    Text("Output").font(.headline)
                    Spacer()
                    Picker("Encoding", selection: $encodingSide) {
                        Text("Match A").tag(0)
                        Text("Match B").tag(1)
                    }
                    .frame(width: 160)
                }
                TextEditor(text: Binding(get: { self.output ?? "" }, set: { self.output = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Resolved text output")
                    .frame(minHeight: 170)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
            if let savedURL {
                Text("Saved \(savedURL.lastPathComponent)")
                    .font(.caption)
                    .help(savedURL.path)
            }
            if let recoveryURL {
                Text("Previous contents are recoverable at \(recoveryURL.path)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { onDone() }
                Spacer()
                if output == nil {
                    Button("Build Output") { buildOutput() }
                        .buttonStyle(.borderedProminent)
                        .disabled(choices.count != comparison.diff.hunks.count)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                } else {
                    Button("Change Choices…") { confirmDiscard = true }
                    Button("Save As…") { saveAs() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: [.command])
                    if canReplaceSources {
                        Menu("Replace Source…") {
                            Button("Replace A") { replaceSource(at: 0) }
                            Button("Replace B") { replaceSource(at: 1) }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 850, minHeight: 660)
        .alert("Unable to Save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Discard edited output and change choices?", isPresented: $confirmDiscard) {
            Button("Discard Output", role: .destructive) {
                output = nil
                savedURL = nil
            }
            Button("Keep Output", role: .cancel) {}
        }
    }

    private func rangeName(_ range: Range<Int>) -> String {
        range.isEmpty ? "insertion at \(range.lowerBound)" : "\(range.lowerBound + 1)–\(range.upperBound)"
    }

    private func preview(_ title: String, lines: [TextLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Text(lines.isEmpty ? "(empty)" : lines.prefix(12).map(\.fullText).joined())
                .font(.system(.caption, design: .monospaced))
                .lineLimit(12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            if lines.count > 12 { Text("… \(lines.count - 12) more lines").font(.caption2) }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assignAll(_ choice: TextChangeChoice) {
        choiceHistory.append(choices)
        choices = Dictionary(uniqueKeysWithValues: comparison.diff.hunks.map { ($0.id, choice) })
    }

    private var nextUnresolvedHunkID: Int? {
        comparison.diff.hunks.first(where: { choices[$0.id] == nil })?.id
    }

    private func chooseNext(_ choice: TextChangeChoice) {
        guard output == nil, let id = nextUnresolvedHunkID else { return }
        choiceHistory.append(choices)
        choices[id] = choice
    }

    private func buildOutput() {
        do {
            output = try TextResolution.resolve(
                left: comparison.left.lines,
                right: comparison.right.lines,
                diff: comparison.diff,
                choices: choices
            ).map(\.fullText).joined()
        } catch { errorMessage = error.localizedDescription }
    }

    private func encodedOutput() throws -> Data {
        guard let output else { return Data() }
        let source = encodingSide == 0 ? comparison.left : comparison.right
        return try TextSnapshot(text: output, encoding: source.encoding,
                                hasByteOrderMark: source.hasByteOrderMark).originalData
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (comparison.sources.last?.lastPathComponent ?? "comparison") + ".resolved"
        panel.directoryURL = comparison.sources.last?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if comparison.sources.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            errorMessage = "Use Replace Source to update A or B with a recovery copy."
            return
        }
        do {
            let data = try encodedOutput()
            if FileManager.default.fileExists(atPath: url.path) {
                let expected = try Data(contentsOf: url, options: .mappedIfSafe)
                recoveryURL = try SafeTextWrite.replace(at: url, expected: expected, with: data).recoveryURL
            } else {
                try SafeTextWrite.create(at: url, data: data)
                recoveryURL = nil
            }
            savedURL = url
        } catch { errorMessage = error.localizedDescription }
    }

    private func replaceSource(at index: Int) {
        guard canReplaceSources, comparison.sources.indices.contains(index) else { return }
        let target = comparison.sources[index]
        let expected = index == 0 ? comparison.left.originalData : comparison.right.originalData
        do {
            recoveryURL = try SafeTextWrite.replace(at: target, expected: expected,
                                                    with: encodedOutput()).recoveryURL
            savedURL = target
        } catch { errorMessage = error.localizedDescription }
    }
}
