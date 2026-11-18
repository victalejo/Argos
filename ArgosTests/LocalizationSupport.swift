//
//  LocalizationSupport.swift
//  ArgosTests
//
//  Utilidades de los tests de localización: leer los catálogos .xcstrings del repo,
//  normalizar claves y literales, y evaluar una clave con la localización inglesa del
//  bundle de la app (los tests corren dentro de Argos.app, en español por el esquema).
//

import Foundation

enum LocalizationSupport {

    /// Raíz del repositorio (este archivo está en ArgosTests/).
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let catalogPaths = [
        "Localization/Localizable.xcstrings",
        "Localization/InfoPlist.xcstrings",
        "ArgosiOS/AppShortcuts.xcstrings",
    ]

    /// Catálogo decodificado (`strings` → entrada) o `nil` si no se puede leer.
    static func catalog(_ relativePath: String) -> [String: Any]? {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["strings"] as? [String: Any]
    }

    // MARK: - Marcadores de formato

    private static let specifierPattern = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-#+ 0]*\d*(?:\.\d+)?(ll|l|h|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])|%%"#
    )

    /// Marcadores de un valor como «posición:tipo» ordenados (`%%` no cuenta).
    static func specifiers(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var position = 0
        var found: [String] = []
        for match in specifierPattern.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), text[whole] != "%%" else { continue }
            position += 1
            let index = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? position
            let length = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            let kind = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            let integer = ["d", "i", "u"].contains(kind)
            found.append("\(index):\(integer ? "d" : length + kind)")
        }
        return found.sorted()
    }

    /// Clave con los marcadores sustituidos por «\u{1}» (para compararla con un literal).
    static func normalizedKey(_ key: String) -> String {
        let escaped = key.replacingOccurrences(of: "%%", with: "\u{2}")
        let range = NSRange(escaped.startIndex..., in: escaped)
        let replaced = specifierPattern.stringByReplacingMatches(in: escaped, range: range, withTemplate: "\u{1}")
        return replaced.replacingOccurrences(of: "\u{2}", with: "%")
    }

    // MARK: - Evaluación en inglés

    /// Bundle de la localización inglesa de la app.
    static var englishBundle: Bundle? {
        Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// Texto inglés de una clave del catálogo con sus argumentos (plurales incluidos).
    static func english(_ key: String, _ arguments: CVarArg...) -> String {
        let format = englishBundle?.localizedString(forKey: key, value: "⟨sin traducir⟩", table: nil) ?? "⟨sin bundle⟩"
        return String(format: format, locale: Locale(identifier: "en_US"), arguments: arguments)
    }
}
