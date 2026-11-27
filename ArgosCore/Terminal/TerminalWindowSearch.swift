//
//  TerminalWindowSearch.swift
//  ArgosCore
//
//  «Buscar en todas las ventanas» de la sesión: un solo comando lee el historial (con las
//  líneas partidas unidas) del panel activo de cada ventana; Argos busca en Swift y
//  muestra la lista por ventana. Al elegir un resultado se cambia a esa ventana y se
//  salta a la coincidencia con el modo copia (ver `TerminalSearchModel.open`).
//
//  Cada bloque empieza con una marca que lleva un aleatorio: el texto del terminal no
//  puede fingir una ventana.
//

import Foundation

/// Una línea con coincidencias en una ventana.
struct TerminalWindowSearchLine: Equatable, Sendable, Identifiable {
    let id: Int
    let text: String
    /// Cuántas coincidencias hay que subir desde la más reciente para llegar a esta línea
    /// (1 = la más reciente de la ventana).
    let ordinalFromNewest: Int
}

/// Resultados de una ventana.
struct TerminalWindowSearchResult: Equatable, Sendable, Identifiable {
    let windowIndex: Int
    let windowName: String
    let matchCount: Int
    /// Las más recientes primero, como mucho `TerminalWindowSearch.maxLinesPerWindow`.
    let lines: [TerminalWindowSearchLine]

    var id: Int { windowIndex }
}

enum TerminalWindowSearch {

    static let maxLinesPerWindow = 200

    static func marker(_ nonce: String) -> String { "ARGOS_SW_\(nonce)" }

    /// Lista las ventanas e imprime, de cada una, `marca|índice|nombre` y su historial.
    static func command(session: String, nonce: String) -> String {
        let mark = marker(nonce)
        return [
            "s=" + ShellQuoting.singleQuoted("=\(session)"),
            "tmux -u list-windows -t \"$s\" -F '#{window_index}|#{window_name}' | while IFS='|' read -r i n; do",
            "  printf '%s|%s|%s\\n' \(mark) \"$i\" \"$n\"",
            "  tmux -u capture-pane -p -J -S -\(TerminalSearchCommands.captureLines) -t \"$s:$i\" </dev/null",
            "done",
        ].joined(separator: "\n")
    }

    /// Ventana → sus líneas de historial, en el orden en que llegaron.
    static func parse(_ output: String, nonce: String) -> [(index: Int, name: String, lines: [String])] {
        let prefix = marker(nonce) + "|"
        var windows: [(index: Int, name: String, lines: [String])] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix(prefix) {
                let fields = line.dropFirst(prefix.count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard let index = fields.first.flatMap({ Int($0) }) else { continue }
                let name = fields.count > 1 ? String(fields[1]) : ""
                windows.append((index: index, name: name, lines: []))
            } else if !windows.isEmpty {
                windows[windows.count - 1].lines.append(line)
            }
        }
        return windows
    }

    /// Resultados de cada ventana con coincidencias.
    static func results(_ output: String, nonce: String, regex: NSRegularExpression) -> [TerminalWindowSearchResult] {
        parse(output, nonce: nonce).compactMap { window in
            result(index: window.index, name: window.name, lines: window.lines, regex: regex)
        }
    }

    static func result(index: Int, name: String, lines: [String], regex: NSRegularExpression) -> TerminalWindowSearchResult? {
        let matches = TerminalSearchMatcher.matches(in: lines, regex: regex)
        guard !matches.isEmpty else { return nil }
        var found: [TerminalWindowSearchLine] = []
        // De la más reciente a la más antigua: una entrada por línea, con el ordinal de su
        // coincidencia más a la derecha (la primera que alcanza la búsqueda hacia atrás).
        var lastLine = -1
        for position in stride(from: matches.count - 1, through: 0, by: -1) where matches[position].line != lastLine {
            let line = matches[position].line
            lastLine = line
            let text = TerminalSearchMatcher.trimmingTrailingSpaces(lines[line])
            found.append(TerminalWindowSearchLine(id: line, text: text, ordinalFromNewest: matches.count - position))
            if found.count == maxLinesPerWindow { break }
        }
        return TerminalWindowSearchResult(windowIndex: index, windowName: name, matchCount: matches.count, lines: found)
    }

    /// Texto de «Copiar coincidencias» con todas las ventanas (más antiguas primero).
    static func copyText(_ results: [TerminalWindowSearchResult]) -> String {
        results.map { result in
            let header = "# \(result.windowIndex): \(result.windowName)"
            return ([header] + result.lines.reversed().map(\.text)).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
