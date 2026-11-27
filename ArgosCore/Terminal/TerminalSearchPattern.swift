//
//  TerminalSearchPattern.swift
//  ArgosCore
//
//  Lo que se busca en el historial del terminal y cómo se le pide a tmux. La búsqueda
//  la hace el MODO COPIA de tmux (resalta todas las coincidencias y mueve el cursor);
//  Argos cuenta las coincidencias por su cuenta sobre `capture-pane` con el mismo patrón
//  para mostrar «3 de 12».
//
//  tmux decide mayúsculas por «smart case»: si el texto buscado no tiene mayúsculas, no
//  las distingue. Para respetar la opción del usuario:
//   - sin distinguir: se le pasa el texto en minúsculas (fuera de los escapes `\x` de una
//     expresión regular, para no convertir `\S` en `\s`);
//   - distinguiendo un texto sin mayúsculas: se busca la expresión `(texto)|A^`. La rama
//     `A^` no puede coincidir nunca (un ancla de inicio tras una letra) pero tiene una
//     mayúscula, y tmux pasa a distinguir.
//

import Foundation

/// Opciones de la barra de búsqueda.
struct TerminalSearchOptions: Equatable, Hashable, Sendable {
    var caseSensitive = false
    var regex = false
    var allWindows = false
}

/// Patrón de búsqueda ya validado.
struct TerminalSearchPattern: Equatable, Sendable {
    let text: String
    let options: TerminalSearchOptions

    /// Orden de copy-mode de tmux y su argumento.
    struct TmuxSearch: Equatable, Sendable {
        /// `search-backward` (expresión regular) o `search-backward-text` (literal).
        let command: String
        let argument: String
    }

    /// Rama imposible con mayúscula que obliga a tmux a distinguir mayúsculas.
    static let forceCaseBranch = "|A^"

    /// `nil` si el texto está vacío. Una expresión regular inválida la detecta `matcher()`.
    init?(text: String, options: TerminalSearchOptions) {
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        self.text = text
        self.options = options
    }

    /// Expresión para contar las coincidencias en Swift (ICU). Lanza si la expresión
    /// regular del usuario no es válida.
    func matcher() throws -> NSRegularExpression {
        let pattern = options.regex ? text : NSRegularExpression.escapedPattern(for: text)
        let flags: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        return try NSRegularExpression(pattern: pattern, options: flags)
    }

    /// Cómo pedírselo a tmux. `supportsRegex`: tmux ≥ 3.1 (antes, `search-backward` era
    /// literal y no había `-text`).
    func tmuxSearch(supportsRegex: Bool) -> TmuxSearch {
        guard supportsRegex else {
            return TmuxSearch(command: "search-backward", argument: options.caseSensitive ? text : text.lowercased())
        }
        let hasUpper = Self.hasUppercase(text)
        if options.regex {
            if !options.caseSensitive {
                return TmuxSearch(command: "search-backward", argument: Self.lowercasingOutsideEscapes(text))
            }
            return TmuxSearch(command: "search-backward", argument: hasUpper ? text : "(\(text))" + Self.forceCaseBranch)
        }
        if !options.caseSensitive {
            return TmuxSearch(command: "search-backward-text", argument: text.lowercased())
        }
        if hasUpper || !Self.hasCasedLetters(text) {
            return TmuxSearch(command: "search-backward-text", argument: text)
        }
        return TmuxSearch(command: "search-backward", argument: "(\(Self.escapedERE(text)))" + Self.forceCaseBranch)
    }

    // MARK: - Utilidades puras

    static func hasUppercase(_ text: String) -> Bool {
        text.contains { $0.isUppercase }
    }

    static func hasCasedLetters(_ text: String) -> Bool {
        text.contains { $0.isCased }
    }

    /// Minúsculas salvo la letra que sigue a una barra invertida (`\S`, `\W`, `\B`…).
    static func lowercasingOutsideEscapes(_ pattern: String) -> String {
        var result = ""
        var escaped = false
        for character in pattern {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                result.append(character)
                escaped = true
            } else {
                result += character.lowercased()
            }
        }
        return result
    }

    /// Escapa los metacaracteres de una expresión regular extendida POSIX (la de tmux).
    static func escapedERE(_ text: String) -> String {
        let special: Set<Character> = ["\\", ".", "[", "]", "(", ")", "{", "}", "*", "+", "?", "|", "^", "$"]
        var result = ""
        for character in text {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// Una coincidencia en una línea del historial.
struct TerminalSearchMatch: Equatable, Sendable {
    /// Línea (0 = la más antigua de lo capturado).
    let line: Int
    /// Columnas en caracteres `[start, end)`.
    let start: Int
    let end: Int
}

/// Busca un patrón en líneas de texto (sin red).
enum TerminalSearchMatcher {

    /// Coincidencias en orden de lectura (de la más antigua a la más reciente).
    static func matches(in lines: [String], regex: NSRegularExpression) -> [TerminalSearchMatch] {
        var found: [TerminalSearchMatch] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for result in regex.matches(in: line, range: range) where result.range.length > 0 {
                guard let swiftRange = Range(result.range, in: line) else { continue }
                let start = line.distance(from: line.startIndex, to: swiftRange.lowerBound)
                let end = line.distance(from: line.startIndex, to: swiftRange.upperBound)
                found.append(TerminalSearchMatch(line: index, start: start, end: end))
            }
        }
        return found
    }

    /// Líneas que tienen alguna coincidencia, sin repetir las consecutivas iguales.
    static func matchingLines(in lines: [String], regex: NSRegularExpression) -> [String] {
        var result: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard regex.firstMatch(in: line, range: range) != nil else { continue }
            let trimmed = trimmingTrailingSpaces(line)
            if result.last != trimmed { result.append(trimmed) }
        }
        return result
    }

    static func trimmingTrailingSpaces(_ line: String) -> String {
        var line = line
        while let last = line.last, last == " " || last == "\t" { line.removeLast() }
        return line
    }
}
