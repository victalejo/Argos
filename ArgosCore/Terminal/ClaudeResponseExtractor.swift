//
//  ClaudeResponseExtractor.swift
//  ArgosCore
//
//  «Copiar la salida del último comando» en una ventana con Claude Code (lógica pura):
//  la última respuesta de texto de Claude, sin la caja del prompt (el borde `╭…╮` o las
//  rayas `────` con `>` en medio), la barra de estado de debajo, el indicador de que está
//  trabajando ni las llamadas a herramientas (`⏺ Bash(…)` y su salida `⎿`).
//
//  En la pantalla de Claude Code cada mensaje suyo empieza con `⏺` y sigue con sangría de
//  dos espacios; los del usuario empiezan con `>` (o `❯`).
//

import Foundation

enum ClaudeResponseExtractor {

    /// Marca de cada mensaje de Claude (según la versión y la fuente, `⏺` o `●`).
    static let bullets: [Character] = ["⏺", "●"]
    /// Indicadores de «trabajando» y de turno terminado («✻ Worked for 12s»).
    static let spinnerCharacters: Set<Character> = ["✻", "✢", "✳", "✶", "✽", "·", "*", "∗"]

    /// La última respuesta de texto, o `nil` si no se reconoce ninguna.
    static func lastResponse(lines rawLines: [String]) -> String? {
        let lines = rawLines.map(TerminalSearchMatcher.trimmingTrailingSpaces)
        let body = withoutTrailingStatus(Array(lines[..<inputBoxStart(lines)]))
        let start = (body.lastIndex(where: isUserMessage) ?? -1) + 1
        let blocks = messageBlocks(Array(body[start...]))
        guard let text = blocks.last(where: { !isToolCall($0) }) ?? blocks.last else { return nil }
        let cleaned = ShellOutputExtractor.joined(dedented(text))
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Piezas

    /// Primera línea de la caja de entrada del final (o el total si no hay caja).
    static func inputBoxStart(_ lines: [String]) -> Int {
        for index in lines.indices.reversed() where isBoxBorder(lines[index]) {
            let after = lines[(index + 1)..<min(lines.count, index + 4)]
            if after.contains(where: isPromptRow) { return index }
        }
        return lines.count
    }

    static func isBoxBorder(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("╭") { return true }
        return trimmed.count >= 10 && trimmed.allSatisfy { $0 == "─" }
    }

    /// Fila de la caja de entrada: `│ > …` o `> …` / `❯ …`.
    static func isPromptRow(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("│") { trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return trimmed.hasPrefix(">") || trimmed.hasPrefix("❯")
    }

    static func isUserMessage(_ line: String) -> Bool {
        line.hasPrefix("> ") || line.hasPrefix("❯ ") || line == ">" || line == "❯"
    }

    /// Quita del final las líneas vacías y las del indicador («✻ Thinking… (esc to interrupt)»).
    static func withoutTrailingStatus(_ lines: [String]) -> [String] {
        var lines = ShellOutputExtractor.trimmedTrailingBlank(lines)
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, spinnerCharacters.contains(first) else { break }
            lines.removeLast()
            lines = ShellOutputExtractor.trimmedTrailingBlank(lines)
        }
        return lines
    }

    /// Mensajes de Claude: cada uno empieza en una línea con `⏺`.
    static func messageBlocks(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        for line in lines {
            if let first = line.first, bullets.contains(first) {
                blocks.append([line])
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks
    }

    /// `⏺ Bash(ls)`, `⏺ Update(main.swift)`, `⏺ Read 3 files (ctrl+o to expand)`…
    static func isToolCall(_ block: [String]) -> Bool {
        guard let first = block.first else { return false }
        let title = first.dropFirst().trimmingCharacters(in: .whitespaces)
        if title.contains("(ctrl+o to expand)") || title.contains("(ctrl+r to expand)") { return true }
        if block.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("⎿") }) { return true }
        let name = title.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" || $0 == "." }
        return !name.isEmpty && title.dropFirst(name.count).hasPrefix("(")
    }

    /// Sin el `⏺` de la primera línea ni la sangría de dos espacios del resto.
    static func dedented(_ block: [String]) -> [String] {
        block.enumerated().map { offset, line in
            if offset == 0 { return line.dropFirst().trimmingCharacters(in: .whitespaces) }
            return line.hasPrefix("  ") ? String(line.dropFirst(2)) : line
        }
    }
}
