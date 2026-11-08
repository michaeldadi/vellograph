import AppKit
import SyntaxCore
import SwiftUI

enum SyntaxLanguage: String, CaseIterable {
    case automatic = "Automatic"
    case plain = "Plain Text"
    case swift = "Swift"
    case javascript = "JavaScript / TypeScript"
    case json = "JSON"
    case python = "Python"
    case xml = "XML / HTML"
    case yaml = "YAML"
    case markdown = "Markdown"
    case shell = "Shell"

    static func detect(path: String?) -> SyntaxLanguage {
        guard let path else { return .plain }
        return switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": .javascript
        case "json", "jsonc": .json
        case "py", "pyi": .python
        case "xml", "html", "htm", "plist", "svg": .xml
        case "yaml", "yml": .yaml
        case "md", "markdown": .markdown
        case "sh", "zsh", "bash", "fish": .shell
        default: .plain
        }
    }

    var dialect: SyntaxDialect {
        switch self {
        case .automatic, .plain: .plain
        case .swift: .swift
        case .javascript: .javascript
        case .json: .json
        case .python: .python
        case .xml: .xml
        case .yaml: .yaml
        case .markdown: .markdown
        case .shell: .shell
        }
    }
}

enum SyntaxTheme: String, CaseIterable {
    case adaptive = "Adaptive"
    case vivid = "Vivid"
    case monochrome = "Monochrome"
}

/// Highlights individual visible lines using precomputed lexical scopes. The
/// comparison view disables this above its size limit.
@MainActor enum SyntaxColoring {
    private enum Token { case keyword, number, string, comment, tag, heading }

    private struct Rule {
        let regex: NSRegularExpression
        let token: Token

        init(_ pattern: String, _ token: Token) {
            // These are fixed, source-controlled patterns, not user input.
            regex = try! NSRegularExpression(pattern: pattern)
            self.token = token
        }
    }

    private static let number = Rule(#"\b\d+(?:\.\d+)?\b"#, .number)
    private static let swiftRules: [Rule] = [
        Rule(#"\b(?:actor|associatedtype|async|await|break|case|catch|class|continue|defer|do|else|enum|extension|false|for|func|guard|if|import|in|init|let|nil|private|protocol|public|return|self|some|static|struct|switch|throw|throws|true|try|var|where|while)\b"#, .keyword),
        number,
    ]
    private static let javascriptRules: [Rule] = [
        Rule(#"\b(?:async|await|break|case|catch|class|const|continue|default|delete|do|else|export|extends|false|finally|for|function|if|import|in|instanceof|interface|let|new|null|return|static|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|yield)\b"#, .keyword),
        number,
    ]
    private static let jsonRules: [Rule] = [
        Rule(#"\b(?:true|false|null)\b"#, .keyword), number,
    ]
    private static let pythonRules: [Rule] = [
        Rule(#"\b(?:and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield)\b"#, .keyword),
        number,
    ]
    private static let xmlRules: [Rule] = [
        Rule(#"</?[A-Za-z_][A-Za-z0-9_.:-]*"#, .tag),
        Rule(#"\b[A-Za-z_][A-Za-z0-9_.:-]*(?=\s*=)"#, .keyword),
    ]
    private static let yamlRules: [Rule] = [
        Rule(#"^\s*[A-Za-z_][A-Za-z0-9_.-]*(?=\s*:)"#, .keyword),
        number,
    ]
    private static let markdownRules: [Rule] = [
        Rule(#"^#{1,6}\s.*$"#, .heading),
        Rule(#"\[[^]]+\]\([^)]+\)"#, .string),
        Rule(#"`[^`]+`"#, .keyword),
    ]
    private static let shellRules: [Rule] = [
        Rule(#"\b(?:case|do|done|elif|else|esac|export|fi|for|function|if|in|local|return|then|while)\b"#, .keyword),
        number,
    ]

    static func text(_ line: String, language: SyntaxLanguage, theme: SyntaxTheme,
                     scopes: [SyntaxScope]) -> Text {
        Text(AttributedString(attributed(line, language: language, theme: theme, scopes: scopes)))
    }

    static func attributed(_ line: String, language: SyntaxLanguage,
                           theme: SyntaxTheme, scopes: [SyntaxScope]) -> NSAttributedString {
        guard language != .plain, language != .automatic, theme != .monochrome,
              line.utf16.count <= 20_000 else { return NSAttributedString(string: line) }
        let rules: [Rule] = switch language {
        case .swift: swiftRules
        case .javascript: javascriptRules
        case .json: jsonRules
        case .python: pythonRules
        case .xml: xmlRules
        case .yaml: yamlRules
        case .markdown: markdownRules
        case .shell: shellRules
        case .automatic, .plain: []
        }
        let value = NSMutableAttributedString(string: line)
        let range = NSRange(location: 0, length: value.length)
        for rule in rules {
            for match in rule.regex.matches(in: line, range: range) {
                value.addAttribute(.foregroundColor, value: color(rule.token, theme: theme),
                                   range: match.range)
            }
        }
        for scope in scopes where scope.start >= 0 && scope.length > 0 &&
            scope.start + scope.length <= value.length {
            let token: Token = scope.kind == .comment ? .comment : .string
            value.addAttribute(.foregroundColor, value: color(token, theme: theme),
                               range: NSRange(location: scope.start, length: scope.length))
        }
        return value
    }

    private static func color(_ token: Token, theme: SyntaxTheme) -> NSColor {
        switch (theme, token) {
        case (.adaptive, .keyword): .systemPurple
        case (.adaptive, .number): .systemOrange
        case (.adaptive, .string): .systemGreen
        case (.adaptive, .comment): .secondaryLabelColor
        case (.adaptive, .tag): .systemBlue
        case (.adaptive, .heading): .systemIndigo
        case (.vivid, .keyword): .systemPink
        case (.vivid, .number): .systemYellow
        case (.vivid, .string): .systemCyan
        case (.vivid, .comment): .tertiaryLabelColor
        case (.vivid, .tag): .systemOrange
        case (.vivid, .heading): .systemTeal
        case (.monochrome, _): .labelColor
        }
    }
}
