import DiffCore
import SwiftUI

struct TextComparisonView: View {
    let comparison: TextComparison
    @State private var layout: Layout = .blocks
    @State private var showLineNumbers = true
    @State private var showInvisibles = false
    @State private var wrapLines = false
    @State private var search = ""
    @State private var currentHunk = 0

    enum Layout: String, CaseIterable {
        case blocks = "Blocks", fluid = "Fluid", unified = "Unified"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Layout", selection: $layout) {
                    ForEach(Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 270)
                Spacer()
                TextField("Find", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityLabel("Find in comparison")
                Toggle("Line Numbers", isOn: $showLineNumbers).toggleStyle(.checkbox)
                Toggle("Wrap", isOn: $wrapLines).toggleStyle(.checkbox)
                Toggle("Invisibles", isOn: $showInvisibles).toggleStyle(.checkbox)
            }
            .padding(10)
            Divider()
            switch layout {
            case .blocks: alignedView
            case .fluid: continuousView
            case .unified: unifiedView
            }
            Divider()
            HStack {
                Text("\(comparison.diff.hunks.count) changes")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Previous", systemImage: "chevron.up") {
                    currentHunk = max(0, currentHunk - 1)
                }
                .disabled(comparison.diff.hunks.isEmpty || currentHunk == 0)
                Button("Next", systemImage: "chevron.down") {
                    currentHunk = min(comparison.diff.hunks.count - 1, currentHunk + 1)
                }
                .disabled(comparison.diff.hunks.isEmpty || currentHunk >= comparison.diff.hunks.count - 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private enum Side { case left, right }

    /// Both panes share one scroll position and blank cells align replacements.
    private var alignedView: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(comparison.rows) { row in
                        let words: WordDifference? = if let old = row.oldIndex, let new = row.newIndex, row.isChanged {
                            WordDiff.compare(comparison.left.lines[old].content, comparison.right.lines[new].content)
                        } else {
                            nil
                        }
                        HStack(alignment: .top, spacing: 0) {
                            lineCell(index: row.oldIndex, side: .left, changed: row.isChanged, segments: words?.old)
                            Divider()
                            lineCell(index: row.newIndex, side: .right, changed: row.isChanged, segments: words?.new)
                        }
                        .frame(minHeight: 22)
                        .id(row.id)
                    }
                }
                .frame(minWidth: 900, maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentHunk) { _, value in
                guard comparison.changeRowIDs.indices.contains(value) else { return }
                withAnimation { proxy.scrollTo(comparison.changeRowIDs[value], anchor: .center) }
            }
        }
    }

    /// Continuous panes preserve their original line spacing.
    private var continuousView: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 0) {
                continuousPane(lines: comparison.left.lines, side: .left)
                Divider()
                continuousPane(lines: comparison.right.lines, side: .right)
            }
            .frame(minWidth: 900)
        }
    }

    private func continuousPane(lines: [TextLine], side: Side) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                lineCell(index: index, side: side, changed: isChanged(index: index, side: side), segments: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unifiedView: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(comparison.diff.operations.indices, id: \.self) { index in
                        let operation = comparison.diff.operations[index]
                        let (marker, line, color): (String, TextLine, Color) = switch operation {
                        case .equal(let old, _): (" ", comparison.left.lines[old], .clear)
                        case .delete(let old): ("−", comparison.left.lines[old], .red.opacity(0.12))
                        case .insert(let new): ("+", comparison.right.lines[new], .green.opacity(0.12))
                        }
                        Text(verbatim: marker + " " + visible(line.content))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(wrapLines ? nil : 1)
                            .fixedSize(horizontal: !wrapLines, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 12)
                            .background(color)
                            .id(index)
                    }
                }
                .frame(minWidth: 900, maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentHunk) { _, value in
                guard comparison.changeOperationIDs.indices.contains(value) else { return }
                withAnimation { proxy.scrollTo(comparison.changeOperationIDs[value], anchor: .center) }
            }
        }
    }

    private func lineCell(index: Int?, side: Side, changed: Bool, segments: [WordSegment]?) -> some View {
        let lines = side == .left ? comparison.left.lines : comparison.right.lines
        let color: Color = side == .left ? .red.opacity(0.12) : .green.opacity(0.12)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showLineNumbers {
                Text(index.map { String($0 + 1) } ?? " ")
                    .frame(width: 54, alignment: .trailing)
                    .foregroundStyle(.tertiary)
            }
            if let index {
                (segments.map { wordText($0, side: side) } ?? Text(verbatim: visible(lines[index].content.isEmpty ? " " : lines[index].content)))
                    .textSelection(.enabled)
                    .lineLimit(wrapLines ? nil : 1)
                    .fixedSize(horizontal: !wrapLines, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(" ").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .frame(minWidth: 450, maxWidth: .infinity, alignment: .leading)
        .background(index.map { searchMatches(lines[$0]) ? Color.yellow.opacity(0.22) : changed ? color : .clear } ?? .clear)
    }

    private func wordText(_ segments: [WordSegment], side: Side) -> Text {
        var value = AttributedString()
        for segment in segments {
            var piece = AttributedString(visible(segment.text))
            piece.foregroundColor = segment.changed ? (side == .left ? .red : .green) : .primary
            value += piece
        }
        return Text(value)
    }

    private func isChanged(index: Int, side: Side) -> Bool {
        let hunks = comparison.diff.hunks
        var lower = 0
        var upper = hunks.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let range = side == .left ? hunks[middle].oldRange : hunks[middle].newRange
            if range.lowerBound <= index { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return false }
        let range = side == .left ? hunks[lower - 1].oldRange : hunks[lower - 1].newRange
        return range.contains(index)
    }

    private func searchMatches(_ line: TextLine) -> Bool {
        !search.isEmpty && line.content.localizedCaseInsensitiveContains(search)
    }

    private func visible(_ text: String) -> String {
        guard showInvisibles else { return text }
        return text.replacingOccurrences(of: " ", with: "·")
            .replacingOccurrences(of: "\t", with: "→")
    }
}
