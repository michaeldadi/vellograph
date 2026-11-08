import DiffCore
import SwiftUI

struct TextComparisonView: View {
    let comparison: TextComparison
    @State private var layout: Layout = .blocks
    @State private var showLineNumbers = true
    @State private var search = ""
    @State private var currentHunk = 0

    enum Layout: String, CaseIterable { case blocks = "Blocks", fluid = "Fluid", unified = "Unified" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Layout", selection: $layout) {
                    ForEach(Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 270)
                Spacer()
                TextField("Find", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Toggle("Line Numbers", isOn: $showLineNumbers).toggleStyle(.checkbox)
            }.padding(10)
            Divider()
            if layout == .unified { unifiedView }
            else { sideBySideView }
            Divider()
            HStack {
                Text("\(comparison.diff.hunks.count) changes")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Previous", systemImage: "chevron.up") { currentHunk = max(0, currentHunk - 1) }
                    .disabled(comparison.diff.hunks.isEmpty || currentHunk == 0)
                Button("Next", systemImage: "chevron.down") {
                    currentHunk = min(comparison.diff.hunks.count - 1, currentHunk + 1)
                }.disabled(comparison.diff.hunks.isEmpty || currentHunk >= comparison.diff.hunks.count - 1)
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var sideBySideView: some View {
        HStack(spacing: 0) {
            linePane(lines: comparison.left.lines, side: .left)
            Divider()
            linePane(lines: comparison.right.lines, side: .right)
        }
    }

    private enum Side { case left, right }

    private func linePane(lines: [TextLine], side: Side) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if showLineNumbers {
                                Text("\(index + 1)")
                                    .frame(width: 54, alignment: .trailing)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(lines[index].content.isEmpty ? " " : lines[index].content)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(lineColor(index: index, side: side))
                        .id(index)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentHunk) { _, value in
                guard comparison.diff.hunks.indices.contains(value) else { return }
                let hunk = comparison.diff.hunks[value]
                let index = side == .left ? hunk.oldRange.lowerBound : hunk.newRange.lowerBound
                withAnimation { proxy.scrollTo(min(index, max(0, lines.count - 1)), anchor: .center) }
            }
        }
    }

    private var unifiedView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comparison.diff.operations.enumerated()), id: \.offset) { _, operation in
                    let (marker, text, color): (String, String, Color) = switch operation {
                    case .equal(let old, _): (" ", comparison.left.lines[old].content, .clear)
                    case .delete(let old): ("−", comparison.left.lines[old].content, .red.opacity(0.13))
                    case .insert(let new): ("+", comparison.right.lines[new].content, .green.opacity(0.13))
                    }
                    Text(marker + " " + text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2).padding(.horizontal, 12)
                        .background(color)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lineColor(index: Int, side: Side) -> Color {
        let isChanged = comparison.diff.hunks.contains {
            (side == .left ? $0.oldRange : $0.newRange).contains(index)
        }
        if !search.isEmpty {
            let lines = side == .left ? comparison.left.lines : comparison.right.lines
            if lines.indices.contains(index), lines[index].content.localizedCaseInsensitiveContains(search) {
                return .yellow.opacity(0.2)
            }
        }
        return isChanged ? (side == .left ? .red.opacity(0.12) : .green.opacity(0.12)) : .clear
    }
}

