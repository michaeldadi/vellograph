import AppKit
import DocumentCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct MetadataComparisonView: View {
    let comparison: FileMetadataComparison
    @State private var details: [FileDetails]
    @State private var previewURL: URL?
    @State private var checkingBytes = false
    @State private var bytesMatch: Bool?
    @State private var errorMessage: String?

    init(comparison: FileMetadataComparison) {
        self.comparison = comparison
        _details = State(initialValue: comparison.sources.map(FileDetails.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("File metadata", systemImage: "doc.questionmark")
                .font(.title2.bold())
            Text(comparison.reason)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(details.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(index == 0 ? "A" : "B"): \(item.url.lastPathComponent)")
                            .font(.headline)
                            .lineLimit(1)
                        LabeledContent("Type", value: item.type)
                        LabeledContent("Size", value: item.size)
                        LabeledContent("Modified", value: item.modified)
                        Text(item.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Quick Look") { previewURL = item.url }
                            Button("Open") { NSWorkspace.shared.open(item.url) }
                            Button("Reveal") {
                                NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if comparison.sources.count == 2 {
                HStack {
                    Button("Compare Exact Bytes") { compareBytes() }
                        .disabled(checkingBytes)
                    if checkingBytes { ProgressView().controlSize(.small) }
                    if let bytesMatch {
                        Label(bytesMatch ? "Identical bytes" : "Different bytes",
                              systemImage: bytesMatch ? "checkmark.circle" : "equal.circle")
                    }
                }
            }
            Button("Refresh Metadata") {
                details = comparison.sources.map(FileDetails.init)
                bytesMatch = nil
            }
            Spacer()
        }
        .padding(20)
        .quickLookPreview($previewURL)
        .alert("File Comparison Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func compareBytes() {
        guard comparison.sources.count == 2 else { return }
        let left = comparison.sources[0]
        let right = comparison.sources[1]
        checkingBytes = true
        bytesMatch = nil
        Task {
            defer { checkingBytes = false }
            do {
                bytesMatch = try await Task.detached(priority: .userInitiated) {
                    try ByteComparison.areIdentical(left, right)
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct FileDetails {
    let url: URL
    let type: String
    let size: String
    let modified: String

    init(_ url: URL) {
        self.url = url
        type = UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "Unknown"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let count = (attributes[.size] as? NSNumber)?.int64Value {
                size = ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
            } else {
                size = "Unknown"
            }
            if let date = attributes[.modificationDate] as? Date {
                modified = date.formatted(date: .abbreviated, time: .shortened)
            } else {
                modified = "Unknown"
            }
        } else {
            size = "Unavailable"
            modified = "Unavailable"
        }
    }
}
