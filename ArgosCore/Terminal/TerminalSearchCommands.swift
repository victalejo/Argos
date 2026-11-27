//
//  TerminalSearchCommands.swift
//  ArgosCore
//
//  Comandos de tmux de la búsqueda en el historial (lógica pura) y la lectura de lo que
//  devuelven. Se mandan por un canal exec APARTE del PTY, no como teclas: así no dependen
//  del prefijo ni del modo de teclas (vi/emacs) del usuario, no se mezclan con lo que
//  teclea, el texto buscado va entrecomillado como un solo argumento (ShellQuoting) y en
//  la misma vuelta se lee la posición del cursor y el historial para contar.
//
//  Todo es POSIX sh, con `tmux -u` (UTF-8 aunque el servidor no tenga locale).
//

import Foundation

/// Panel sobre el que se busca: el activo de una ventana de la sesión (o de la activa).
struct TerminalPaneTarget: Equatable, Hashable, Sendable {
    let session: String
    /// `nil`: la ventana activa.
    let window: Int?

    /// Destino EXACTO de tmux (`=sesión:ventana`): sin `=`, tmux aceptaría un prefijo.
    var tmuxTarget: String {
        "=\(session):" + (window.map(String.init) ?? "")
    }
}

/// Versión de tmux (`tmux -V`): qué órdenes de copy-mode existen.
struct TmuxVersion: Comparable, Sendable {
    let major: Int
    let minor: Int

    /// `nil` si no se reconoce. `tmux master` / `tmux next-3.6` cuentan como recientes.
    init?(versionOutput: String) {
        let text = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("tmux ") else { return nil }
        var rest = String(text.dropFirst(5))
        if rest == "master" {
            self.init(major: 99, minor: 0)
            return
        }
        if rest.hasPrefix("next-") { rest = String(rest.dropFirst(5)) }
        let parts = rest.split(separator: ".", maxSplits: 1)
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minorDigits = parts.count > 1 ? String(parts[1].prefix { $0.isNumber }) : "0"
        self.init(major: major, minor: Int(minorDigits) ?? 0)
    }

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// `search-backward` con expresiones regulares y las variantes `-text` (3.1).
    var supportsRegexSearch: Bool { self >= TmuxVersion(major: 3, minor: 1) }
    /// Marcas OSC 133 y `previous-prompt`/`next-prompt` (3.4).
    var supportsPromptMarks: Bool { self >= TmuxVersion(major: 3, minor: 4) }
}

/// Posición del cursor del modo copia tras una búsqueda.
struct TerminalSearchPosition: Equatable, Sendable {
    let inMode: Bool
    let historySize: Int
    /// Línea absoluta del cursor (0 = la más antigua del historial), si tmux la da.
    let line: Int?
    let column: Int?
    /// `search_present` (tmux ≥ 3.2); `nil` si no se sabe.
    let searchPresent: Bool?

    /// Formato de `display -p` que lee `init(displayLine:)`.
    static let format = "#{pane_in_mode}|#{history_size}|#{scroll_position}|#{copy_cursor_y}|#{copy_cursor_x}|#{search_present}"

    init?(displayLine: String) {
        let fields = displayLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, let history = Int(fields[1]) else { return nil }
        inMode = fields[0] == "1"
        historySize = history
        if let scroll = Int(fields[2]), let y = Int(fields[3]) {
            line = history - scroll + y
        } else {
            line = nil
        }
        column = Int(fields[4])
        searchPresent = fields[5].isEmpty ? nil : fields[5] == "1"
    }
}

/// Resultado de una búsqueda en el panel: posición y lo capturado para contar.
struct TerminalSearchSnapshot: Equatable, Sendable {
    let position: TerminalSearchPosition?
    /// Filas del panel (sin unir las partidas), de la más antigua a la más reciente.
    let lines: [String]
    /// Línea absoluta de `lines[0]`.
    let firstLine: Int
    /// No se capturó todo el historial (más de `TerminalSearchCommands.captureLines`).
    let isPartial: Bool
    /// El panel salió del modo copia (el usuario pulsó `q`, otro cliente…).
    let leftCopyMode: Bool
}

enum TerminalSearchCommands {

    /// Líneas de historial que se leen para contar (el historial de Argos es de 50 000).
    static let captureLines = 20_000

    static let versionCommand = "tmux -V"

    static func nonce() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    static func positionMarker(_ nonce: String) -> String { "ARGOS_TS_POS_\(nonce)" }
    static func textMarker(_ nonce: String) -> String { "ARGOS_TS_TEXT_\(nonce)" }
    static func goneMarker(_ nonce: String) -> String { "ARGOS_TS_GONE_\(nonce)" }

    private static func targetLine(_ target: TerminalPaneTarget) -> String {
        "t=" + ShellQuoting.singleQuoted(target.tmuxTarget)
    }

    private static func reportPosition(_ nonce: String) -> [String] {
        [
            "printf '%s\\n' \(positionMarker(nonce))",
            "tmux -u display -p -t \"$t\" \(ShellQuoting.singleQuoted(TerminalSearchPosition.format))",
        ]
    }

    /// Entra en modo copia, va al final y busca hacia atrás (la coincidencia más reciente);
    /// imprime la posición y las últimas `captureLines` filas para contar.
    static func start(target: TerminalPaneTarget, search: TerminalSearchPattern.TmuxSearch, nonce: String) -> String {
        var lines = [
            targetLine(target),
            "tmux -u copy-mode -t \"$t\" || exit 3",
            "tmux -u send-keys -t \"$t\" -X history-bottom",
            "tmux -u send-keys -t \"$t\" -X \(search.command) \(ShellQuoting.singleQuoted(search.argument))",
        ]
        lines += reportPosition(nonce)
        lines += [
            "printf '%s\\n' \(textMarker(nonce))",
            "tmux -u capture-pane -p -S -\(captureLines) -t \"$t\"",
        ]
        return lines.joined(separator: "\n")
    }

    /// Repite la búsqueda `count` veces: hacia coincidencias más antiguas (`older`) o más
    /// recientes. Como la primera búsqueda es hacia atrás, `search-again` sube y
    /// `search-reverse` baja. Si el panel ya no está en modo copia, avisa sin teclear nada.
    static func step(target: TerminalPaneTarget, older: Bool, count: Int = 1, nonce: String) -> String {
        let order = older ? "search-again" : "search-reverse"
        let repeatFlag = count > 1 ? "-N \(count) " : ""
        var lines = [
            targetLine(target),
            "[ \"$(tmux -u display -p -t \"$t\" '#{pane_mode}')\" = copy-mode ] || { printf '%s\\n' \(goneMarker(nonce)); exit 0; }",
            "tmux -u send-keys -t \"$t\" -X \(repeatFlag)\(order)",
        ]
        lines += reportPosition(nonce)
        return lines.joined(separator: "\n")
    }

    /// Sale del modo copia (quita el resaltado) solo si el panel sigue en él.
    static func cancel(target: TerminalPaneTarget) -> String {
        [
            targetLine(target),
            "[ \"$(tmux -u display -p -t \"$t\" '#{pane_mode}')\" = copy-mode ] && tmux -u send-keys -t \"$t\" -X cancel",
            "exit 0",
        ].joined(separator: "\n")
    }

    /// Historial con las líneas partidas unidas (para «Copiar coincidencias»).
    static func captureJoined(target: TerminalPaneTarget) -> String {
        "tmux -u capture-pane -p -J -S -\(captureLines) -t " + ShellQuoting.singleQuoted(target.tmuxTarget)
    }

    static func selectWindow(session: String, window: Int) -> String {
        "tmux -u select-window -t " + ShellQuoting.singleQuoted("=\(session):\(window)")
    }

    // MARK: - Lectura

    /// Lee la salida de `start` o `step`. `nil` si no trae la marca de posición.
    static func parse(_ output: String, nonce: String) -> TerminalSearchSnapshot? {
        if output.contains(goneMarker(nonce)) {
            return TerminalSearchSnapshot(position: nil, lines: [], firstLine: 0, isPartial: false, leftCopyMode: true)
        }
        let all = output.components(separatedBy: "\n")
        guard let positionIndex = all.firstIndex(of: positionMarker(nonce)) else { return nil }
        let position = all.indices.contains(positionIndex + 1) ? TerminalSearchPosition(displayLine: all[positionIndex + 1]) : nil
        var captured: [String] = []
        if let textIndex = all.firstIndex(of: textMarker(nonce)) {
            captured = Array(all[(textIndex + 1)...])
            if captured.last == "" { captured.removeLast() }
        }
        let history = position?.historySize ?? 0
        let firstLine = max(0, history - captureLines)
        return TerminalSearchSnapshot(
            position: position,
            lines: captured,
            firstLine: firstLine,
            isPartial: history > captureLines,
            leftCopyMode: position.map { !$0.inMode } ?? false
        )
    }

    /// Número de la coincidencia en la que está el cursor, contando desde la MÁS RECIENTE
    /// (1 = la última). `nil` si la posición no se sabe o no cae cerca de ninguna.
    static func currentIndex(
        position: TerminalSearchPosition?, matches: [TerminalSearchMatch], firstLine: Int
    ) -> Int? {
        guard let position, let line = position.line, !matches.isEmpty else { return nil }
        let relative = line - firstLine
        let column = position.column ?? 0
        let onLine = matches.indices.filter { matches[$0].line == relative }
        // tmux deja el cursor al principio de la coincidencia (o al final al ir hacia
        // delante): vale cualquier columna dentro de ella.
        let index = onLine.first { matches[$0].start <= column && column <= matches[$0].end } ?? onLine.first
        guard let index else { return nil }
        return matches.count - index
    }
}
