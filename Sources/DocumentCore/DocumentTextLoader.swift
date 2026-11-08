import DiffCore
import Foundation
import PDFKit

public enum DocumentTextError: Error, LocalizedError, Equatable {
    case unreadablePDF
    case noExtractableText
    case conversionFailed
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            "This PDF could not be opened. It may be damaged or password protected."
        case .noExtractableText:
            "No selectable text was found. A scanned PDF needs OCR before text comparison."
        case .conversionFailed:
            "macOS could not extract text from this Word document."
        case .outputTooLarge:
            "The extracted text exceeds the 100 MB comparison limit."
        }
    }
}

public struct LoadedDocumentText: Sendable {
    public let snapshot: TextSnapshot
    public let note: String?

    public init(snapshot: TextSnapshot, note: String?) {
        self.snapshot = snapshot
        self.note = note
    }
}

public enum DocumentTextLoader {
    public static func isExtractableDocument(_ url: URL) -> Bool {
        ["pdf", "doc", "docx", "rtf", "odt"].contains(url.pathExtension.lowercased())
    }

    public static func load(_ url: URL) throws -> LoadedDocumentText {
        switch url.pathExtension.lowercased() {
        case "pdf": return try loadPDF(url)
        case "doc", "docx", "rtf", "odt": return try loadWord(url)
        default:
            return LoadedDocumentText(
                snapshot: try TextSnapshot(data: Data(contentsOf: url, options: .mappedIfSafe)),
                note: nil
            )
        }
    }

    private static func loadPDF(_ url: URL) throws -> LoadedDocumentText {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw DocumentTextError.unreadablePDF
        }
        var pages: [String] = []
        var emptyPages = 0
        for index in 0..<document.pageCount {
            try Task<Never, Never>.checkCancellation()
            let value = document.page(at: index)?.string ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyPages += 1
            } else {
                pages.append(value)
            }
        }
        guard !pages.isEmpty else { throw DocumentTextError.noExtractableText }
        let text = pages.joined(separator: "\n\n")
        guard text.utf8.count <= 100_000_000 else { throw DocumentTextError.outputTooLarge }
        let note = emptyPages == 0
            ? "PDF text only; page layout, images, and annotations are omitted."
            : "PDF text only; \(emptyPages) of \(document.pageCount) pages had no selectable text. Images and annotations are omitted."
        return LoadedDocumentText(snapshot: try TextSnapshot(text: text), note: note)
    }

    private static func loadWord(_ url: URL) throws -> LoadedDocumentText {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", "-encoding", "UTF-8", "--", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw DocumentTextError.conversionFailed }

        var data = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 100_000_000 {
                    process.terminate()
                    process.waitUntilExit()
                    throw DocumentTextError.outputTooLarge
                }
            }
        } catch let error as DocumentTextError {
            throw error
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw DocumentTextError.conversionFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw DocumentTextError.conversionFailed
        }
        return LoadedDocumentText(
            snapshot: try TextSnapshot(data: data),
            note: "Extracted text only; formatting, images, comments, and tracked changes may be omitted."
        )
    }
}
