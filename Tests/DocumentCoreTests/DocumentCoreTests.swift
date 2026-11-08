import DocumentCore
import Foundation
import Testing

@Test func richTextIsExtractedWithoutChangingSource() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "example.rtf")
    let original = Data("{\\rtf1\\ansi Hello \\b world\\b0 !}".utf8)
    try original.write(to: url)

    let loaded = try DocumentTextLoader.load(url)
    #expect(loaded.snapshot.text.contains("Hello world!"))
    #expect(loaded.note?.contains("formatting") == true)
    #expect(try Data(contentsOf: url) == original)
}

@Test func unsupportedPlainTextPreservesOriginalBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "example.txt")
    let original = Data([0xEF, 0xBB, 0xBF]) + Data("first\r\nsecond".utf8)
    try original.write(to: url)

    let loaded = try DocumentTextLoader.load(url)
    #expect(loaded.note == nil)
    #expect(try loaded.snapshot.encode(loaded.snapshot.lines) == original)
}

@Test func documentTypeRecognition() {
    for name in ["a.pdf", "b.DOCX", "c.doc", "d.rtf", "e.odt"] {
        #expect(DocumentTextLoader.isExtractableDocument(URL(fileURLWithPath: name)))
    }
    #expect(!DocumentTextLoader.isExtractableDocument(URL(fileURLWithPath: "file.txt")))
}

@Test func exactByteComparisonStreamsAcrossChunkBoundaries() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let left = directory.appending(path: "left.bin")
    let right = directory.appending(path: "right.bin")
    let original = Data(repeating: 0xA5, count: 140_000)
    try original.write(to: left)
    try original.write(to: right)
    #expect(try ByteComparison.areIdentical(left, right))

    var changed = original
    changed[100_000] = 0x5A
    try changed.write(to: right)
    #expect(try !ByteComparison.areIdentical(left, right))
}
