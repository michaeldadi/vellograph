import Foundation
import Testing
@testable import DiffCore

@Test func jsonNormalizationAndOrderedFiltersLeaveSourceUntouched() throws {
    let original = Data("{\"b\":2,\"a\":\"redacted\"}".utf8)
    let source = try TextSnapshot(data: original)
    let options = TextPreparationOptions(
        normalizeJSON: true,
        filters: [TextReplacementFilter(pattern: "redacted", replacement: "value")]
    )
    let prepared = try TextPreparation.prepare(source, options: options)
    #expect(prepared.text == "{\n  \"a\" : \"value\",\n  \"b\" : 2\n}\n")
    #expect(source.originalData == original)
}

@Test func invalidFilterAndJSONDoNotProducePartialSnapshot() throws {
    let source = try TextSnapshot(text: "hello")
    #expect(throws: TextPreparationError.self) {
        try TextPreparation.prepare(source, options: .init(filters: [
            TextReplacementFilter(pattern: "[", replacement: "x")
        ]))
    }
    #expect(throws: TextPreparationError.invalidJSON) {
        try TextPreparation.prepare(source, options: .init(normalizeJSON: true))
    }
}

@Test func unifiedPatchIncludesContextAndNoNewlineMarker() throws {
    let old = try TextSnapshot(text: "one\ntwo\nthree")
    let new = try TextSnapshot(text: "one\nTWO\nthree")
    let diff = try DiffEngine.compare(old.lines, new.lines)
    let patch = UnifiedPatch.generate(oldLabel: "a.txt", newLabel: "b.txt",
                                      old: old.lines, new: new.lines, diff: diff, context: 1)
    #expect(patch.contains("@@ -1,3 +1,3 @@"))
    #expect(patch.contains("-two\n+TWO\n"))
    #expect(patch.contains(" three\n\\ No newline at end of file\n"))
}
