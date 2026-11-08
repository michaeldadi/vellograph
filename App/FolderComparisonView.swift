import FolderCore
import SwiftUI

struct FolderComparisonView: View {
    let entries: [FolderDifference]
    @State private var query = ""
    @State private var showEqual = false

    private var filtered: [FolderDifference] {
        entries.filter { entry in
            (showEqual || entry.state != .equal) &&
            (query.isEmpty || entry.relativePath.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entries.filter { $0.state != .equal }.count) differences")
                    .font(.headline)
                Spacer()
                Toggle("Show Equal", isOn: $showEqual).toggleStyle(.checkbox)
                TextField("Filter paths", text: $query).frame(width: 220)
            }.padding(12)
            List(filtered) { entry in
                HStack {
                    Image(systemName: entry.kind == .directory ? "folder" : "doc")
                    Text(entry.relativePath).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(entry.state.rawValue).foregroundStyle(.secondary)
                }
            }
        }
    }
}

