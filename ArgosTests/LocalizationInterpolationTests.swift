//
//  LocalizationInterpolationTests.swift
//  ArgosTests
//
//  La CI compila con Xcode 16.4 (SDK de macOS 15 / iOS 18), cuyo
//  `String.LocalizationValue.StringInterpolation` SOLO admite interpolar `String`,
//  números, `NSObject`, `AttributedString`, `LocalizedStringResource` y `(valor,
//  format:)`. El SDK nuevo acepta además `Substring`, `Character`, `Error` o cualquier
//  otro tipo, así que lo que compila aquí puede romper la CI. Este test señala las
//  interpolaciones de `String(localized:)` cuyo tipo no es claramente `String` o número:
//  envuélvelas en `String(…)` / `String(describing:)` (la clave del catálogo, `%@`, no
//  cambia).
//

import Foundation
import Testing

@Suite("Localización: interpolaciones compatibles con Xcode 16.4")
struct LocalizationInterpolationTests {

    /// Expresiones que se sabe que son `String`/número aunque el patrón las señale.
    static let whitelist: Set<String> = []

    @Test("String(localized:) solo interpola String o números claros")
    func interpolationsAreOldSDKCompatible() throws {
        var offenders: [String] = []
        for file in LocalizationCatalogTests.sourceFiles() {
            let relative = String(file.path.dropFirst(LocalizationSupport.repoRoot.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SourceStringScanner.literals(in: source) where literal.isExplicitlyLocalized {
                for expression in Self.interpolations(in: literal.text) {
                    if let reason = Self.problem(with: expression), !Self.whitelist.contains(expression) {
                        offenders.append("\(relative):\(literal.line)  \\(\(expression))  → \(reason)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, """
            \(offenders.count) interpolaciones que el SDK de Xcode 16.4 puede rechazar. Envuélvelas \
            en String(…) o String(describing:) (la clave del catálogo no cambia):
            \(offenders.joined(separator: "\n"))
            """)
    }

    @Test("la regla detecta los casos conocidos y deja pasar los seguros", arguments: [
        ("reply.prefix(200)", true), ("tail.suffix(600)", true), ("name.dropFirst()", true),
        ("text.dropLast(2)", true), ("error", true), ("err", true), ("character", true),
        ("name.first", true), ("value[a..<b]", true),
        ("String(reply.prefix(200))", false), ("String(describing: error)", false),
        ("error.userMessage", false), ("server.name", false), ("count", false),
        ("files.count - 3", false), ("names.joined(separator: \", \")", false),
    ])
    func ruleCatchesKnownCases(expression: String, flagged: Bool) {
        #expect((Self.problem(with: expression) != nil) == flagged, "«\(expression)»")
    }

    // MARK: - Regla

    /// Nombres que suelen ser `Error`, `Character` o `Substring`.
    private static let suspiciousNames: Set<String> = [
        "error", "err", "e", "character", "char", "ch", "c", "substring", "slice", "sub",
    ]

    /// Motivo por el que la expresión puede no compilar con el SDK antiguo, o `nil`.
    static func problem(with raw: String) -> String? {
        let expression = raw.trimmingCharacters(in: .whitespaces)
        if isWrapped(expression, in: ["String(", "Int(", "Double("]) { return nil }
        if expression.range(of: #"\.(prefix|suffix|dropFirst|dropLast|trimmingPrefix)\b"#, options: .regularExpression) != nil {
            return "devuelve Substring"
        }
        if expression.range(of: #"\.(first|last)$"#, options: .regularExpression) != nil {
            return "puede ser Character u opcional"
        }
        if expression.range(of: #"\[[^\]]*\.\.[<.]"#, options: .regularExpression) != nil {
            return "un rango de una cadena es Substring"
        }
        let last = expression.split(separator: ".").last.map(String.init) ?? expression
        if suspiciousNames.contains(expression) || (suspiciousNames.contains(last) && !expression.contains("(")) {
            return "tipo no evidente (¿Error / Character?)"
        }
        return nil
    }

    /// `true` si toda la expresión es `Prefijo(…)` con el paréntesis final cerrando el inicial.
    private static func isWrapped(_ expression: String, in prefixes: [String]) -> Bool {
        guard let prefix = prefixes.first(where: { expression.hasPrefix($0) }), expression.hasSuffix(")") else { return false }
        var depth = 0
        for (index, char) in expression.enumerated() {
            if char == "(" { depth += 1 }
            if char == ")" {
                depth -= 1
                if depth == 0 { return index == expression.count - 1 && index >= prefix.count - 1 }
            }
        }
        return false
    }

    /// Expresiones de las interpolaciones `\(…)` de un literal crudo.
    static func interpolations(in text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var i = 0
        while i + 1 < chars.count {
            guard chars[i] == "\\", chars[i + 1] == "(" else { i += 1; continue }
            let end = SourceStringScanner.skipParentheses(chars, from: i + 1)
            if end - 1 > i + 2 { result.append(String(chars[(i + 2)..<(end - 1)])) }
            i = end
        }
        return result
    }
}
