//
//  SyntaxHighlighter.swift
//  Argos
//
//  Resaltado de sintaxis LIGERO (sin dependencias): un escáner de una pasada que
//  reconoce comentarios, cadenas, números y palabras clave del lenguaje. No es un
//  parser: busca que el código se lea bien, no exactitud de compilador. Lógica pura;
//  la vista traduce cada `Token.Kind` a un color del tema.
//

import Foundation

enum SyntaxHighlighter {

    struct Token: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case comment, string, number, keyword
        }
        let kind: Kind
        /// Rango en unidades UTF-16 (compatible con `NSRange`/`NSAttributedString`).
        let range: NSRange
    }

    /// Por encima de esto no se resalta (el texto se muestra plano, sin coste).
    static let maxHighlightedLength = 300_000

    private struct Syntax {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        var keywords: Set<String> = []
    }

    private static let cFamilyKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "return", "true", "false", "null", "new", "class", "struct", "enum", "import",
        "export", "const", "static", "public", "private", "protected", "void", "try",
        "catch", "throw", "finally", "this", "super", "extends", "implements", "interface",
    ]

    private static func syntax(for language: String?) -> Syntax? {
        switch language {
        case "swift":
            return Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: cFamilyKeywords.union([
                "func", "let", "var", "guard", "in", "init", "self", "Self", "nil", "async",
                "await", "throws", "some", "any", "protocol", "extension", "where", "defer",
                "inout", "final", "override", "mutating", "actor", "fileprivate", "internal",
            ]))
        case "typescript", "javascript":
            return Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: cFamilyKeywords.union([
                "function", "let", "var", "async", "await", "of", "in", "typeof", "instanceof",
                "undefined", "from", "as", "type", "yield", "delete", "readonly", "keyof",
            ]))
        case "python":
            return Syntax(lineComments: ["#"], quotes: ["\"", "'"], keywords: [
                "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
                "and", "or", "is", "None", "True", "False", "import", "from", "as", "with",
                "try", "except", "finally", "raise", "lambda", "yield", "async", "await",
                "pass", "break", "continue", "self", "global", "nonlocal",
            ])
        case "go":
            return Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: cFamilyKeywords.union([
                "func", "package", "var", "type", "map", "chan", "go", "defer", "range",
                "select", "nil", "iota", "fallthrough", "goto",
            ]))
        case "rust":
            return Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: cFamilyKeywords.union([
                "fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "match", "loop",
                "self", "Self", "crate", "where", "async", "await", "move", "ref", "Some", "None", "Ok", "Err",
            ]))
        case "java", "kotlin", "csharp", "c", "cpp", "dart", "php":
            return Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], keywords: cFamilyKeywords.union([
                "int", "long", "float", "double", "char", "bool", "boolean", "string",
                "fun", "val", "var", "function", "namespace", "using", "include", "define",
            ]))
        case "ruby":
            return Syntax(lineComments: ["#"], quotes: ["\"", "'"], keywords: [
                "def", "end", "class", "module", "if", "elsif", "else", "unless", "while",
                "do", "return", "nil", "true", "false", "self", "require", "yield", "begin", "rescue",
            ])
        case "shell":
            return Syntax(lineComments: ["#"], quotes: ["\"", "'"], keywords: [
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                "case", "esac", "function", "return", "export", "local", "echo", "exit",
                "FROM", "RUN", "COPY", "WORKDIR", "CMD", "ENV", "EXPOSE", "ENTRYPOINT", "ARG",
            ])
        case "yaml", "toml":
            return Syntax(lineComments: ["#"], quotes: ["\"", "'"], keywords: ["true", "false", "null", "yes", "no"])
        case "json":
            return Syntax(quotes: ["\""], keywords: ["true", "false", "null"])
        case "sql":
            return Syntax(lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""], keywords: [
                "select", "from", "where", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "alter", "drop", "join", "left", "right", "inner",
                "on", "and", "or", "not", "null", "primary", "key", "references", "index",
                "group", "by", "order", "limit", "as", "distinct", "returning",
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "JOIN", "ON", "AND", "OR",
                "NOT", "NULL", "PRIMARY", "KEY", "REFERENCES", "GROUP", "BY", "ORDER", "LIMIT", "AS",
            ])
        case "html", "css":
            return Syntax(blockComment: language == "html" ? ("<!--", "-->") : ("/*", "*/"), quotes: ["\"", "'"])
        default:
            return nil
        }
    }

    /// Tokens del texto para `language` (`nil`/desconocido o texto enorme → sin tokens).
    static func tokens(in text: String, language: String?) -> [Token] {
        guard let syntax = syntax(for: language) else { return [] }
        let units = Array(text.utf16)
        guard units.count <= maxHighlightedLength else { return [] }

        var tokens: [Token] = []
        var index = 0
        let count = units.count

        func matches(_ pattern: String, at position: Int) -> Bool {
            let p = Array(pattern.utf16)
            guard position + p.count <= count else { return false }
            for offset in 0..<p.count where units[position + offset] != p[offset] { return false }
            return true
        }

        func isIdentifier(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F // _
        }

        let quoteUnits = Set(syntax.quotes.compactMap { $0.utf16.first })
        let newline: UInt16 = 0x0A

        while index < count {
            let unit = units[index]

            // Comentario de línea.
            if let marker = syntax.lineComments.first(where: { matches($0, at: index) }) {
                var end = index + marker.utf16.count
                while end < count && units[end] != newline { end += 1 }
                tokens.append(Token(kind: .comment, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // Comentario de bloque.
            if let block = syntax.blockComment, matches(block.open, at: index) {
                var end = index + block.open.utf16.count
                while end < count && !matches(block.close, at: end) { end += 1 }
                end = min(count, end + block.close.utf16.count)
                tokens.append(Token(kind: .comment, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // Cadena (respeta escapes; las de comillas simples/dobles no cruzan líneas).
            if quoteUnits.contains(unit) {
                let multiline = unit == 0x60 // `
                var end = index + 1
                while end < count && units[end] != unit {
                    if units[end] == 0x5C { end += 1 } // \ escapa el siguiente
                    else if units[end] == newline && !multiline { break }
                    end += 1
                }
                end = min(count, end + 1)
                tokens.append(Token(kind: .string, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // Número (no pegado a un identificador: "v2" no es número).
            if (0x30...0x39).contains(unit), index == 0 || !isIdentifier(units[index - 1]) {
                var end = index + 1
                while end < count, isIdentifier(units[end]) || units[end] == 0x2E { end += 1 } // dígitos, ., x, e…
                tokens.append(Token(kind: .number, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // Identificador / palabra clave.
            if isIdentifier(unit) {
                var end = index + 1
                while end < count && isIdentifier(units[end]) { end += 1 }
                if !syntax.keywords.isEmpty,
                   syntax.keywords.contains(String(decoding: units[index..<end], as: UTF16.self)) {
                    tokens.append(Token(kind: .keyword, range: NSRange(location: index, length: end - index)))
                }
                index = end
                continue
            }

            index += 1
        }
        return tokens
    }
}
