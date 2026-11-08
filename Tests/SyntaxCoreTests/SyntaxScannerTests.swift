import SyntaxCore
import Testing

struct SyntaxScannerTests {
    @Test func swiftNestedCommentAndFollowingCode() {
        let lines = ["let a = 1 /* outer", "nested /* inner */ still outer", "done */ let b = 2"]
        let scopes = SyntaxScanner.scan(lines, dialect: .swift)
        #expect(scopes[0] == [SyntaxScope(start: 10, length: 8, kind: .comment)])
        #expect(scopes[1] == [SyntaxScope(start: 0, length: 30, kind: .comment)])
        #expect(scopes[2] == [SyntaxScope(start: 0, length: 7, kind: .comment)])
    }

    @Test func commentMarkersInsideQuotedTextStayStrings() {
        let lines = [#"let url = "https://example.com/a/*b" // real"#]
        let scopes = SyntaxScanner.scan(lines, dialect: .swift)[0]
        #expect(scopes.count == 2)
        #expect(scopes[0].kind == .string)
        #expect(scopes[1].kind == .comment)
        #expect(scopes[0].start + scopes[0].length <= scopes[1].start)
    }

    @Test func pythonTripleQuotedStringContinuesAcrossLines() {
        let lines = ["value = '''first", "# still a string", "last''' # comment"]
        let scopes = SyntaxScanner.scan(lines, dialect: .python)
        #expect(scopes[0].last?.kind == .string)
        #expect(scopes[1] == [SyntaxScope(start: 0, length: 16, kind: .string)])
        #expect(scopes[2].map(\.kind) == [.string, .comment])
    }

    @Test func xmlCommentAndUnicodeOffsets() {
        let lines = ["😀<!-- note", "continued --> <tag>"]
        let scopes = SyntaxScanner.scan(lines, dialect: .xml)
        #expect(scopes[0] == [SyntaxScope(start: 2, length: 9, kind: .comment)])
        #expect(scopes[1] == [SyntaxScope(start: 0, length: 13, kind: .comment)])
    }

    @Test func javascriptTemplateAndLineComment() {
        let lines = ["const x = `one", "// still template` // real"]
        let scopes = SyntaxScanner.scan(lines, dialect: .javascript)
        #expect(scopes[0].last?.kind == .string)
        #expect(scopes[1].map(\.kind) == [.string, .comment])
    }
}
