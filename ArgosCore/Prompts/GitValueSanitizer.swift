//
//  GitValueSanitizer.swift
//  ArgosCore
//
//  Limpieza de lo que dice git antes de meterlo en un prompt (lógica pura). Rama, nombres
//  de archivo y asunto del commit los controla quien escribe en el repo, y el prompt puede
//  ir a un agente que actúa sin preguntar: los nombres solo conservan caracteres seguros y
//  el asunto queda en una línea corta, con su hash delante.
//

import Foundation

enum GitValueSanitizer {
    /// Tope de un nombre (rama o archivo).
    static let maxNameLength = 200
    /// Tope del asunto del commit (sin el hash).
    static let maxSubjectLength = 120
    /// Lo que sustituye a un carácter que no es seguro.
    static let replacement: Character = "?"

    /// Caracteres ASCII que se conservan en un nombre, además de las letras Unicode.
    private static let safeASCII = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@+-")

    /// Rama o nombre de archivo: solo `[A-Za-z0-9._/@+-]` y letras Unicode; lo demás
    /// (espacios, comillas, signos, controles, marcas de dirección) pasa a `?`. `nil` si
    /// no queda nada.
    static func safeName(_ raw: String) -> String? {
        let mapped = raw.prefix(maxNameLength).map { (character: Character) -> Character in
            isSafe(character) ? character : replacement
        }
        let text = String(mapped)
        return text.allSatisfy({ $0 == replacement }) ? nil : text
    }

    /// `hash asunto` de `git log --format='%h %s'`: hash corto en hexadecimal y el asunto
    /// en una línea, sin controles y recortado. `nil` si no empieza por un hash válido.
    static func commitLine(_ raw: String) -> String? {
        let line = PromptText.singleLine(raw)
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let hash = parts.first, isShortHash(hash) else { return nil }
        let subject = parts.count > 1 ? String(parts[1].prefix(maxSubjectLength)) : ""
        return subject.isEmpty ? String(hash) : "\(hash) \(subject)"
    }

    /// Ruta de una línea de `git status --porcelain` sin el estado (`XY `): de un
    /// renombrado (`vieja -> nueva`) se queda la nueva, y una ruta entrecomillada por
    /// `core.quotePath` pierde las comillas (sus escapes octales quedan como `?`).
    static func porcelainPath(_ entry: String) -> String? {
        var path = entry
        if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        return safeName(path)
    }

    private static func isSafe(_ character: Character) -> Bool {
        if character.isASCII { return safeASCII.contains(character) }
        return character.isLetter && character.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            scalar.properties.isAlphabetic || scalar.properties.generalCategory == .nonspacingMark
        }
    }

    private static func isShortHash(_ text: Substring) -> Bool {
        (4...40).contains(text.count) && text.allSatisfy { (character: Character) -> Bool in
            character.isASCII && character.isHexDigit && !character.isUppercase
        }
    }
}
