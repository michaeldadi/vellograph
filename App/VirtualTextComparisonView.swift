import AppKit
import DiffCore
import SyntaxCore
import SwiftUI

/// AppKit creates only visible rows. SwiftUI LazyVStack still constructed a
/// very large accessibility/layout tree for long side-by-side comparisons.
struct VirtualTextComparisonView: NSViewRepresentable {
    let comparison: TextComparison
    let layout: TextComparisonView.Layout
    let showLineNumbers: Bool
    let showInvisibles: Bool
    let syntaxLanguage: SyntaxLanguage
    let syntaxTheme: SyntaxTheme
    let colorSyntax: Bool
    let leftSyntaxScopes: [[SyntaxScope]]
    let rightSyntaxScopes: [[SyntaxScope]]
    let syntaxVersion: UUID
    let search: String
    let contentVersion: UUID
    let scrollRequest: UUID?
    let targetRow: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnResizing = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        for (identifier, title) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.minWidth = 240
            column.width = layout == .unified ? 900 : 500
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.reloadData()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let redraw = coordinator.contentVersion != contentVersion ||
            coordinator.showLineNumbers != showLineNumbers ||
            coordinator.showInvisibles != showInvisibles || coordinator.search != search
            || coordinator.syntaxLanguage != syntaxLanguage || coordinator.syntaxTheme != syntaxTheme
            || coordinator.colorSyntax != colorSyntax
            || coordinator.syntaxVersion != syntaxVersion
        coordinator.comparison = comparison
        coordinator.showLineNumbers = showLineNumbers
        coordinator.showInvisibles = showInvisibles
        coordinator.search = search
        coordinator.syntaxLanguage = syntaxLanguage
        coordinator.syntaxTheme = syntaxTheme
        coordinator.colorSyntax = colorSyntax
        coordinator.leftSyntaxScopes = leftSyntaxScopes
        coordinator.rightSyntaxScopes = rightSyntaxScopes
        coordinator.syntaxVersion = syntaxVersion
        coordinator.contentVersion = contentVersion
        if redraw { table.reloadData() }
        if let scrollRequest, scrollRequest != coordinator.lastScrollRequest,
           let targetRow, targetRow >= 0, targetRow < coordinator.numberOfRows(in: table) {
            coordinator.lastScrollRequest = scrollRequest
            table.scrollRowToVisible(targetRow)
        }
    }

    private var columns: [(String, String)] {
        layout == .unified ? [("unified", "Unified")] : [("left", "A"), ("right", "B")]
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var comparison: TextComparison
        let layout: TextComparisonView.Layout
        var showLineNumbers: Bool
        var showInvisibles: Bool
        var search: String
        var syntaxLanguage: SyntaxLanguage
        var syntaxTheme: SyntaxTheme
        var colorSyntax: Bool
        var leftSyntaxScopes: [[SyntaxScope]]
        var rightSyntaxScopes: [[SyntaxScope]]
        var syntaxVersion: UUID
        var contentVersion: UUID
        var lastScrollRequest: UUID?

        init(_ parent: VirtualTextComparisonView) {
            comparison = parent.comparison
            layout = parent.layout
            showLineNumbers = parent.showLineNumbers
            showInvisibles = parent.showInvisibles
            search = parent.search
            syntaxLanguage = parent.syntaxLanguage
            syntaxTheme = parent.syntaxTheme
            colorSyntax = parent.colorSyntax
            leftSyntaxScopes = parent.leftSyntaxScopes
            rightSyntaxScopes = parent.rightSyntaxScopes
            syntaxVersion = parent.syntaxVersion
            contentVersion = parent.contentVersion
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            switch layout {
            case .blocks: comparison.rows.count
            case .fluid: max(comparison.left.lines.count, comparison.right.lines.count)
            case .unified: comparison.diff.operations.count
            }
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let column else { return nil }
            let label = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            label.identifier = column.identifier
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.isSelectable = true
            label.drawsBackground = true
            let cell = content(for: column.identifier.rawValue, row: row)
            label.attributedStringValue = attributedText(for: cell, column: column.identifier.rawValue)
            label.backgroundColor = cell.searchHit ? .systemYellow.withAlphaComponent(0.18) :
                cell.changed ? (column.identifier.rawValue == "left" ?
                    .systemRed.withAlphaComponent(0.12) : .systemGreen.withAlphaComponent(0.12)) :
                .clear
            label.toolTip = cell.text.count > 200 ? String(cell.text.prefix(200)) + "…" : nil
            return label
        }

        private struct CellContent {
            let text: String
            let prefixLength: Int
            let changed: Bool
            let searchHit: Bool
            let words: [WordSegment]?
            let scopes: [SyntaxScope]
        }

        private func content(for column: String, row: Int) -> CellContent {
            let line: TextLine?
            let number: Int?
            let changed: Bool
            let marker: String
            var words: [WordSegment]?
            let leftSource: Bool
            switch layout {
            case .blocks:
                let entry = comparison.rows[row]
                number = column == "left" ? entry.oldIndex : entry.newIndex
                line = number.map { column == "left" ? comparison.left.lines[$0] : comparison.right.lines[$0] }
                changed = entry.isChanged
                marker = ""
                leftSource = column == "left"
                if let old = entry.oldIndex, let new = entry.newIndex, changed {
                    let difference = WordDiff.compare(comparison.left.lines[old].content,
                                                      comparison.right.lines[new].content)
                    words = column == "left" ? difference.old : difference.new
                }
            case .fluid:
                let lines = column == "left" ? comparison.left.lines : comparison.right.lines
                number = lines.indices.contains(row) ? row : nil
                line = number.map { lines[$0] }
                changed = number.map { isChanged($0, left: column == "left") } ?? false
                marker = ""
                leftSource = column == "left"
            case .unified:
                let operation = comparison.diff.operations[row]
                switch operation {
                case .equal(let old, _):
                    number = old; line = comparison.left.lines[old]; changed = false; marker = " "
                    leftSource = true
                case .delete(let old):
                    number = old; line = comparison.left.lines[old]; changed = true; marker = "−"
                    leftSource = true
                case .insert(let new):
                    number = new; line = comparison.right.lines[new]; changed = true; marker = "+"
                    leftSource = false
                }
            }
            guard let line else { return CellContent(text: "", prefixLength: 0,
                                                      changed: false, searchHit: false, words: nil,
                                                      scopes: []) }
            let sourceScopes = leftSource ? leftSyntaxScopes : rightSyntaxScopes
            let scopes = number.flatMap { sourceScopes.indices.contains($0) ? sourceScopes[$0] : nil } ?? []
            var content = line.content
            if showInvisibles {
                content = content.replacingOccurrences(of: " ", with: "·")
                    .replacingOccurrences(of: "\t", with: "→")
            }
            let prefix = showLineNumbers ? String(format: "%7d  ", (number ?? 0) + 1) : ""
            let text = marker.isEmpty ? prefix + content : marker + " " + prefix + content
            return CellContent(text: text, prefixLength: (marker.isEmpty ? prefix : marker + " " + prefix).utf16.count,
                               changed: changed,
                               searchHit: !search.isEmpty && line.content.localizedCaseInsensitiveContains(search),
                               words: words, scopes: scopes)
        }

        private func attributedText(for cell: CellContent, column: String) -> NSAttributedString {
            let result = NSMutableAttributedString(string: cell.text)
            let whole = NSRange(location: 0, length: result.length)
            result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                  .foregroundColor: NSColor.labelColor], range: whole)
            guard cell.prefixLength < result.length else { return result }
            let body = String((cell.text as NSString).substring(from: cell.prefixLength))
            if colorSyntax {
                let colored = SyntaxColoring.attributed(body, language: syntaxLanguage,
                                                        theme: syntaxTheme, scopes: cell.scopes)
                colored.enumerateAttribute(.foregroundColor,
                                           in: NSRange(location: 0, length: colored.length)) { value, range, _ in
                    if let value { result.addAttribute(.foregroundColor, value: value,
                                                       range: NSRange(location: cell.prefixLength + range.location,
                                                                      length: range.length)) }
                }
            }
            if let words = cell.words {
                var offset = cell.prefixLength
                for segment in words {
                    let length = segment.text.utf16.count
                    if segment.changed && offset + length <= result.length {
                        result.addAttribute(.foregroundColor,
                                            value: column == "left" ? NSColor.systemRed : NSColor.systemGreen,
                                            range: NSRange(location: offset, length: length))
                    }
                    offset += length
                }
            }
            return result
        }

        private func isChanged(_ index: Int, left: Bool) -> Bool {
            var lower = 0
            var upper = comparison.diff.hunks.count
            while lower < upper {
                let middle = (lower + upper) / 2
                let range = left ? comparison.diff.hunks[middle].oldRange :
                    comparison.diff.hunks[middle].newRange
                if range.lowerBound <= index { lower = middle + 1 } else { upper = middle }
            }
            guard lower > 0 else { return false }
            let range = left ? comparison.diff.hunks[lower - 1].oldRange :
                comparison.diff.hunks[lower - 1].newRange
            return range.contains(index)
        }
    }
}
