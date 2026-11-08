import GitCore
import SwiftUI

struct RepositoryView: View {
    let repository: GitRepository
    let workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(repository.root.lastPathComponent).font(.title2.bold())
                    Text(repository.branch ?? "Detached HEAD").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(repository.status.count) changed items")
            }.padding()
            Divider()
            List(repository.status) { entry in
                HStack {
                    Text(String(entry.indexStatus) + String(entry.worktreeStatus))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 35)
                    Text(entry.path).font(.system(.body, design: .monospaced))
                    Spacer()
                    if entry.isPartiallyStaged { Text("Partial").foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { await workspace.open(urls: [repository.root.appendingPathComponent(entry.path)]) }
                }
            }
        }
    }
}

