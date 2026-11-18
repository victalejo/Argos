//
//  SourceStringScanner.swift
//  ArgosTests
//
//  Lector mínimo de fuentes Swift para el test de «ninguna cadena de interfaz fuera del
//  catálogo»: encuentra los literales de una línea (no los multilínea, que son scripts
//  remotos) con su línea y si están dentro de una llamada de registro (`Log.*`, `print`…),
//  saltando comentarios e interpolaciones.
//

import Foundation

struct SourceLiteral: Equatable {
    let line: Int
    /// Contenido crudo, con las interpolaciones `\(…)` tal cual.
    let text: String
    /// Dentro de `Log.x.y(…)`, `print(…)`, `fatalError(…)`…
    let isInLogCall: Bool
    /// Justo después de `String(localized:` / `LocalizedStringResource(`.
    let isExplicitlyLocalized: Bool
    /// Es el `comment:` de una cadena localizada (nota para el traductor).
    let isComment: Bool
    /// Nombre de una vista previa de Xcode (`#Preview("…")`).
    let isPreviewName: Bool

    /// El literal con las interpolaciones sustituidas por «\u{1}» y los escapes resueltos.
    var normalized: String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            guard char == "\\", next < text.endIndex else {
                out.append(char)
                index = next
                continue
            }
            switch text[next] {
            case "(":
                index = SourceStringScanner.skipParentheses(in: text, from: next)
                out.append("\u{1}")
                continue
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "u":
                // \u{XXXX}
                if let close = text[next...].firstIndex(of: "}"),
                   let scalar = UInt32(text[text.index(next, offsetBy: 2)..<close], radix: 16).flatMap(Unicode.Scalar.init) {
                    out.unicodeScalars.append(scalar)
                    index = text.index(after: close)
                    continue
                }
                out.append("\\u")
            default: out.append(text[next])
            }
            index = text.index(after: next)
        }
        return out
    }
}

enum SourceStringScanner {

    private static let logCalls = ["print", "debugPrint", "fatalError", "precondition", "preconditionFailure",
                                   "assert", "assertionFailure"]

    static func literals(in source: String) -> [SourceLiteral] {
        let chars = Array(source)
        var result: [SourceLiteral] = []
        var calls: [String] = []
        var line = 1
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            if c == "#" || c == "\"" {
                var hashes = 0
                var j = i
                while j < chars.count, chars[j] == "#" { hashes += 1; j += 1 }
                guard j < chars.count, chars[j] == "\"" else { i += 1; continue }
                let multiline = j + 2 < chars.count && chars[j + 1] == "\"" && chars[j + 2] == "\""
                let start = j + (multiline ? 3 : 1)
                let (end, after) = scanString(chars, from: start, multiline: multiline, hashes: hashes)
                if !multiline && hashes == 0 {
                    let prefix = String(chars[max(0, i - 40)..<i])
                    result.append(SourceLiteral(
                        line: line,
                        text: String(chars[start..<end]),
                        isInLogCall: calls.contains(where: isLogCall),
                        isExplicitlyLocalized: prefix.range(of: #"(String|AttributedString)\(localized:\s*$|LocalizedStringResource\(\s*$"#,
                                                            options: .regularExpression) != nil,
                        isComment: prefix.range(of: #"comment:\s*$"#, options: .regularExpression) != nil,
                        isPreviewName: prefix.range(of: #"#Preview\(\s*$"#, options: .regularExpression) != nil
                    ))
                }
                line += chars[i..<min(after, chars.count)].filter { $0 == "\n" }.count
                i = after
                continue
            }
            if c == "(" || c == "[" {
                calls.append(c == "(" ? identifier(before: i, in: chars) : "")
            } else if c == ")" || c == "]" {
                _ = calls.popLast()
            }
            i += 1
        }
        return result
    }

    private static func isLogCall(_ name: String) -> Bool {
        name.hasPrefix("Log.") || name.contains("logger.") || logCalls.contains(name)
    }

    private static func identifier(before index: Int, in chars: [Character]) -> String {
        var j = index - 1
        while j >= 0, chars[j] == " " { j -= 1 }
        var name: [Character] = []
        while j >= 0, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." {
            name.insert(chars[j], at: 0)
            j -= 1
        }
        return String(name)
    }

    /// Devuelve (fin del contenido, índice tras el cierre).
    private static func scanString(_ chars: [Character], from start: Int, multiline: Bool, hashes: Int) -> (Int, Int) {
        let closing = Array(String(repeating: "\"", count: multiline ? 3 : 1) + String(repeating: "#", count: hashes))
        var i = start
        while i < chars.count {
            if chars[i...].starts(with: closing) { return (i, i + closing.count) }
            if chars[i] == "\\" && hashes == 0 {
                if i + 1 < chars.count, chars[i + 1] == "(" {
                    i = skipParentheses(chars, from: i + 1)
                    continue
                }
                i += 2
                continue
            }
            if chars[i] == "\n" && !multiline { return (i, i) }
            i += 1
        }
        return (chars.count, chars.count)
    }

    /// Índice tras el `)` que cierra el `(` de `index` (respeta cadenas anidadas simples).
    static func skipParentheses(_ chars: [Character], from index: Int) -> Int {
        var depth = 0
        var i = index
        while i < chars.count {
            switch chars[i] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return i + 1 }
            case "\"":
                i += 1
                while i < chars.count, chars[i] != "\"" { i += chars[i] == "\\" ? 2 : 1 }
            default: break
            }
            i += 1
        }
        return chars.count
    }

    static func skipParentheses(in text: String, from index: String.Index) -> String.Index {
        let chars = Array(text[index...])
        let end = skipParentheses(chars, from: 0)
        return text.index(index, offsetBy: end, limitedBy: text.endIndex) ?? text.endIndex
    }
}
