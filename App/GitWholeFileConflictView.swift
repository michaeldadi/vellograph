import GitCore
import SwiftUI

struct GitWholeFileConflictView: View {
    let comparison: GitWholeFileConflictComparison
    let onSaved: (URL) -> Void

    @State private var choice: GitWholeFileChoice?
    @State private var isSaving = false
    @State private var saved = false
    @State private var recoveryURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Whole-file Git conflict", systemImage: "arrow.triangle.merge")
                .font(.title2.bold())
            Text(comparison.path)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("A side was deleted or contains content that cannot be merged as text. Choose the entire working file, then stage the resolution with Git after reviewing it.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                stage("Common base", data: comparison.stages.base)
                stage("Ours", data: comparison.stages.ours)
                stage("Theirs", data: comparison.stages.theirs)
            }
            HStack(spacing: 12) {
                choiceButton("Use Ours", .ours)
                choiceButton("Use Theirs", .theirs)
                choiceButton("Delete Working File", .delete)
            }
            Text("The Git index stays unmerged. A replaced or deleted working file keeps a local recovery copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recoveryURL {
                Text("Recovery: \(recoveryURL.path)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack {
                if saved { Label("Saved to working copy", systemImage: "checkmark.circle") }
                Spacer()
                Button(isSaving ? "Saving…" : "Apply to Working File") { saveChoice() }
                    .buttonStyle(.borderedProminent)
                    .disabled(choice == nil || isSaving || saved)
            }
        }
        .padding(20)
        .alert("Conflict Save Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func stage(_ title: String, data: Data?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(data.map { ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file) }
                 ?? "Deleted")
                .font(.system(.body, design: .monospaced))
            if let data, data.isEmpty { Text("Empty file").foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func choiceButton(_ label: String, _ value: GitWholeFileChoice) -> some View {
        Button {
            choice = value
        } label: {
            Label(label, systemImage: choice == value ? "checkmark.circle.fill" : "circle")
        }
        .disabled(isSaving || saved)
    }

    private func saveChoice() {
        guard let choice else { return }
        isSaving = true
        let comparison = comparison
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GitClient().saveWholeFileConflict(
                        in: comparison.repositoryRoot, path: comparison.path,
                        expectedStages: comparison.stages,
                        expectedWorkingFile: comparison.expectedOutput, choice: choice
                    )
                }.value
                recoveryURL = result.recoveryURL
                saved = true
                onSaved(comparison.outputURL)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
