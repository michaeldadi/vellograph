import AppKit
import DiffCore

@MainActor enum TextPrintExport {
    enum ExportError: LocalizedError {
        case tooLarge
        case failed

        var errorDescription: String? {
            switch self {
            case .tooLarge: "This comparison is too large to print. Export a patch instead."
            case .failed: "The print or PDF export did not finish."
            }
        }
    }

    static func printComparison(_ comparison: TextComparison) throws {
        let operation = try makeOperation(comparison)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        _ = operation.run()
    }

    static func exportPDF(_ comparison: TextComparison, to url: URL) throws {
        let operation = try makeOperation(comparison)
        let info = operation.printInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url as NSURL
        operation.printInfo = info
        operation.showsPrintPanel = false
        operation.showsProgressPanel = true
        guard operation.run() else { throw ExportError.failed }
    }

    private static func makeOperation(_ comparison: TextComparison) throws -> NSPrintOperation {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        let output = NSMutableAttributedString(string: "")
        let leftName = comparison.sources.first?.lastPathComponent ?? "Before"
        let rightName = comparison.sources.dropFirst().first?.lastPathComponent ?? "After"
        output.append(NSAttributedString(string: "\(leftName) ↔ \(rightName)\n\n", attributes: attributes))
        for operation in comparison.diff.operations {
            try Task<Never, Never>.checkCancellation()
            let prefix: String
            let line: TextLine
            let color: NSColor
            switch operation {
            case .equal(let old, _):
                prefix = "  "; line = comparison.left.lines[old]; color = .textColor
            case .delete(let old):
                prefix = "− "; line = comparison.left.lines[old]; color = .systemRed
            case .insert(let new):
                prefix = "+ "; line = comparison.right.lines[new]; color = .systemGreen
            }
            var lineAttributes = attributes
            lineAttributes[.foregroundColor] = color
            output.append(NSAttributedString(string: prefix + line.content + "\n", attributes: lineAttributes))
            if output.length > 10_000_000 { throw ExportError.tooLarge }
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 700))
        view.isEditable = false
        view.isRichText = true
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(output)
        view.sizeToFit()
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        return NSPrintOperation(view: view, printInfo: info)
    }
}
