//
//  ShellOutputExtractor.swift
//  ArgosCore
//
//  «Copiar la salida del último comando» en una ventana con shell (lógica pura):
//
//   - Con marcas OSC 133 (bloque opcional en .zshrc/.bashrc, ver `ShellIntegrationBlock`):
//     tmux ≥ 3.6 las enseña en `capture-pane -F` (`P` = prompt, `O` = empieza la salida);
//     con tmux 3.4/3.5, `previous-prompt -o`/`next-prompt` del modo copia dan el rango.
//   - Sin marcas, heurística: la última línea es el prompt actual; la salida es lo que hay
//     entre el prompt anterior (con la misma «forma») y él.
//

import Foundation

enum ShellOutputExtractor {

    // MARK: - Con `capture-pane -F`

    enum MarkedResult: Equatable {
        case output(String)
        /// No hay marcas de salida: se usa la heurística.
        case noMarks
    }

    /// Líneas de `capture-pane -p -J -F`: `<banderas> <texto>`.
    static func markedOutput(flaggedLines: [String]) -> MarkedResult {
        let parsed: [(flags: Substring, text: String)] = flaggedLines.map { line in
            guard let space = line.firstIndex(of: " ") else { return (flags: Substring(line), text: "") }
            return (flags: line[..<space], text: String(line[line.index(after: space)...]))
        }
        guard let outputStart = parsed.lastIndex(where: { $0.flags.contains("O") }) else { return .noMarks }
        if parsed[outputStart].flags.contains("P") { return .output("") }
        let end = parsed[(outputStart + 1)...].firstIndex { $0.flags.contains("P") } ?? parsed.count
        return .output(joined(parsed[outputStart..<end].map(\.text)))
    }

    // MARK: - Con `previous-prompt -o` / `next-prompt` (tmux 3.4/3.5)

    /// `bottom`, `start` y `end` son líneas absolutas (0 = la más antigua del historial):
    /// el final del panel, el principio de la última salida y el prompt siguiente.
    static func rangedOutput(rows: [String], firstLine: Int, bottom: Int, start: Int, end: Int) -> MarkedResult {
        // Si `previous-prompt -o` no movió el cursor, no hay marcas.
        guard start != bottom || end != bottom else { return .noMarks }
        let from = start - firstLine
        let to = (end > start ? end : firstLine + rows.count) - firstLine
        guard from >= 0, from <= to, to <= rows.count else { return .noMarks }
        return .output(joined(Array(rows[from..<to])))
    }

    /// Posición `historia|scroll|y` de `display -p` → línea absoluta.
    static func absoluteLine(_ field: String) -> Int? {
        let parts = field.split(separator: "|").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] - parts[1] + parts[2]
    }

    // MARK: - Heurística

    /// Salida entre los dos últimos prompts. `nil` si la última línea no parece un prompt
    /// o no hay un prompt anterior que se le parezca.
    static func heuristicOutput(lines rawLines: [String]) -> String? {
        let lines = trimmedTrailingBlank(rawLines.map(TerminalSearchMatcher.trimmingTrailingSpaces))
        guard let current = lines.indices.last, let prompt = PromptShape(line: lines[current]) else { return nil }
        guard let previous = lines[..<current].lastIndex(where: { prompt.matches($0) }) else { return nil }
        var end = current
        // Prompt de dos líneas (cabecera + «❯»): la cabecera del actual no es salida.
        if end - 1 > previous, previous > 0, let header = PromptShape.firstWord(lines[end - 1]),
           PromptShape.firstWord(lines[previous - 1]) == header {
            end -= 1
        }
        return joined(Array(lines[(previous + 1)..<end]))
    }

    // MARK: - Utilidades

    static func joined(_ lines: [String]) -> String {
        trimmedTrailingBlank(lines.map(TerminalSearchMatcher.trimmingTrailingSpaces)).joined(separator: "\n")
    }

    static func trimmedTrailingBlank(_ lines: [String]) -> [String] {
        var lines = lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines
    }
}

/// «Forma» de un prompt: su comienzo estable y el símbolo que lo cierra.
struct PromptShape: Equatable {
    /// Lo que va antes del primer espacio o `:` (usuario@máquina, `(venv)`, `❯`…).
    let head: String
    let terminator: String
    /// Largo del prompt de la línea de la que salió.
    let length: Int

    static let terminators = ["$", "#", "%", ">", "❯", "➜", "λ", "»"]
    /// Un prompt no suele ser más largo; más allá, un `$` es parte de la orden.
    static let maxPromptLength = 160

    init?(line: String) {
        guard let (terminator, end) = Self.firstTerminator(in: line) else { return nil }
        let prompt = String(line.prefix(end))
        guard let head = Self.firstWord(prompt) else { return nil }
        self.head = head
        self.terminator = terminator
        self.length = end
    }

    /// ¿`line` empieza con un prompt de esta forma?
    func matches(_ line: String) -> Bool {
        guard line.hasPrefix(head), let (terminator, end) = Self.firstTerminator(in: line) else { return false }
        guard terminator == self.terminator, end <= length + 60 else { return false }
        // Un prompt que es solo el símbolo («$ », «❯ »): la línea debe empezar igual.
        if head == terminator { return line == terminator || line.hasPrefix(terminator + " ") }
        return true
    }

    /// Primer símbolo de cierre seguido de espacio (o al final de la línea) y el largo
    /// del prompt hasta él (incluido).
    static func firstTerminator(in line: String) -> (String, Int)? {
        let characters = Array(line.prefix(maxPromptLength))
        for (offset, character) in characters.enumerated() where terminators.contains(String(character)) {
            let atEnd = offset == characters.count - 1 && characters.count == line.count
            let followedBySpace = offset + 1 < characters.count && characters[offset + 1] == " "
            if atEnd || followedBySpace { return (String(character), offset + 1) }
        }
        return nil
    }

    static func firstWord(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let word = trimmed.prefix { $0 != " " && $0 != ":" }
        return word.isEmpty ? nil : String(word)
    }
}
