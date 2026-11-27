//
//  TerminalLastOutput.swift
//  ArgosCore
//
//  «Copiar la salida del último comando»: el comando que lee el panel (con las marcas
//  OSC 133 si las hay) y la elección de lo que se copia según lo que corre en la ventana
//  (shell o Claude Code). Lógica pura + un modelo pequeño para el aviso de la interfaz.
//

import Foundation
import Observation

enum TerminalLastOutput {

    /// Qué corre en la ventana.
    enum Kind: Equatable, Sendable {
        case shell
        case claude
    }

    enum Failure: Error, Equatable {
        /// No se reconoce el prompt (o la respuesta de Claude).
        case notRecognized
        /// El último comando no escribió nada.
        case empty
    }

    /// Líneas que se leen del historial (la última salida suele estar cerca del final).
    static let captureLines = 5000

    static func flagsMarker(_ nonce: String) -> String { "ARGOS_LO_F_\(nonce)" }
    static func rangeMarker(_ nonce: String) -> String { "ARGOS_LO_R_\(nonce)" }
    static func textMarker(_ nonce: String) -> String { "ARGOS_LO_T_\(nonce)" }

    /// Lee el panel activo de `target`. En un shell, primero prueba `capture-pane -F`
    /// (tmux ≥ 3.6, marcas en cada línea); si no existe y `navigateMarks` (el bloque OSC 133
    /// está instalado), busca el rango con `previous-prompt -o`/`next-prompt` en el modo
    /// copia, solo si el panel no estaba ya en él (no se le mueve el cursor al usuario).
    static func command(target: TerminalPaneTarget, kind: Kind, navigateMarks: Bool, nonce: String) -> String {
        var lines = ["t=" + ShellQuoting.singleQuoted(target.tmuxTarget)]
        if kind == .shell {
            lines += [
                "if tmux -u capture-pane -p -F -S 0 -E 0 -t \"$t\" >/dev/null 2>&1; then",
                "  printf '%s\\n' \(flagsMarker(nonce))",
                "  tmux -u capture-pane -p -J -F -S -\(captureLines) -t \"$t\"",
                "  exit 0",
                "fi",
            ]
            if navigateMarks {
                lines += [
                    "f='#{history_size}|#{scroll_position}|#{copy_cursor_y}'",
                    "if [ \"$(tmux -u display -p -t \"$t\" '#{pane_in_mode}')\" = 0 ] && tmux -u copy-mode -t \"$t\"; then",
                    "  tmux -u send-keys -t \"$t\" -X history-bottom",
                    "  z=$(tmux -u display -p -t \"$t\" \"$f\")",
                    "  tmux -u send-keys -t \"$t\" -X previous-prompt -o 2>/dev/null",
                    "  a=$(tmux -u display -p -t \"$t\" \"$f\")",
                    "  tmux -u send-keys -t \"$t\" -X next-prompt 2>/dev/null",
                    "  b=$(tmux -u display -p -t \"$t\" \"$f\")",
                    "  tmux -u send-keys -t \"$t\" -X cancel",
                    "  printf '%s;%s;%s;%s\\n' \(rangeMarker(nonce)) \"$z\" \"$a\" \"$b\"",
                    "  printf '%s\\n' \(textMarker(nonce))",
                    "  tmux -u capture-pane -p -S -\(captureLines) -t \"$t\"",
                    "  exit 0",
                    "fi",
                ]
            }
        }
        lines += [
            "printf '%s\\n' \(textMarker(nonce))",
            "tmux -u capture-pane -p -J -S -\(captureLines) -t \"$t\"",
        ]
        return lines.joined(separator: "\n")
    }

    /// Lo que se copia, a partir de la salida de `command`.
    static func extract(_ output: String, kind: Kind, nonce: String) -> Result<String, Failure> {
        var all = output.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        if let flags = all.firstIndex(of: flagsMarker(nonce)) {
            let flagged = Array(all[(flags + 1)...])
            if case .output(let text) = ShellOutputExtractor.markedOutput(flaggedLines: flagged) {
                return result(text)
            }
            // Sin marcas: la misma captura, sin las banderas.
            return heuristic(flagged.map(stripFlags), kind: kind)
        }
        guard let textIndex = all.firstIndex(of: textMarker(nonce)) else { return .failure(.notRecognized) }
        let rows = Array(all[(textIndex + 1)...])
        if let rangeLine = all.first(where: { $0.hasPrefix(rangeMarker(nonce) + ";") }),
           case .output(let text) = ranged(rangeLine, rows: rows) {
            return result(text)
        }
        return heuristic(rows, kind: kind)
    }

    private static func ranged(_ line: String, rows: [String]) -> ShellOutputExtractor.MarkedResult {
        let fields = line.split(separator: ";", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard fields.count == 3,
              let bottom = ShellOutputExtractor.absoluteLine(fields[0]),
              let start = ShellOutputExtractor.absoluteLine(fields[1]),
              let end = ShellOutputExtractor.absoluteLine(fields[2]),
              let history = fields[0].split(separator: "|").first.flatMap({ Int($0) }) else { return .noMarks }
        let firstLine = max(0, history - captureLines)
        return ShellOutputExtractor.rangedOutput(rows: rows, firstLine: firstLine, bottom: bottom, start: start, end: end)
    }

    private static func heuristic(_ lines: [String], kind: Kind) -> Result<String, Failure> {
        let text: String?
        switch kind {
        case .shell: text = ShellOutputExtractor.heuristicOutput(lines: lines)
        case .claude: text = ClaudeResponseExtractor.lastResponse(lines: lines)
        }
        guard let text else { return .failure(.notRecognized) }
        return result(text)
    }

    private static func result(_ text: String) -> Result<String, Failure> {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failure(.empty) : .success(text)
    }

    static func stripFlags(_ line: String) -> String {
        guard let space = line.firstIndex(of: " ") else { return "" }
        return String(line[line.index(after: space)...])
    }
}

/// Estado del aviso de «Copiar la salida del último comando» (Mac e iPhone/iPad).
@MainActor
@Observable
final class TerminalLastOutputModel {

    enum State: Equatable {
        case idle
        case working
        case copied(lines: Int)
        case info(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let run: TerminalSearchModel.Runner
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    init(run: @escaping TerminalSearchModel.Runner) {
        self.run = run
    }

    /// Lee y copia con `copy` (el portapapeles de cada plataforma).
    func copyLastOutput(
        target: TerminalPaneTarget, kind: TerminalLastOutput.Kind, navigateMarks: Bool, copy: @escaping (String) -> Void
    ) async {
        guard state != .working else { return }
        state = .working
        let nonce = TerminalSearchCommands.nonce()
        let command = TerminalLastOutput.command(target: target, kind: kind, navigateMarks: navigateMarks, nonce: nonce)
        do {
            let output = try await run(command)
            switch TerminalLastOutput.extract(output, kind: kind, nonce: nonce) {
            case .success(let text):
                copy(text)
                show(.copied(lines: text.components(separatedBy: "\n").count))
            case .failure(.empty):
                show(.failed(String(localized: "El último comando no escribió nada.")))
            case .failure(.notRecognized):
                show(.failed(kind == .claude
                    ? String(localized: "No se encontró la última respuesta de Claude.")
                    : String(localized: "No se reconoce el prompt. Activa las marcas de prompt (OSC 133) para que sea exacto.")))
            }
        } catch {
            show(.failed(error.userMessage))
        }
    }

    /// Otro aviso del terminal en el mismo sitio (p. ej. las marcas de prompt).
    func notify(_ message: String, isError: Bool) {
        show(isError ? .failed(message) : .info(message))
    }

    var isError: Bool {
        if case .failed = state { return true }
        return false
    }

    func dismiss() {
        resetTask?.cancel()
        state = .idle
    }

    private func show(_ newState: State) {
        state = newState
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.state = .idle
        }
    }

    var message: String? {
        switch state {
        case .idle: return nil
        case .working: return String(localized: "Leyendo la salida…")
        case .copied(let lines):
            return lines == 1
                ? String(localized: "Copiada 1 línea")
                : String(localized: "Copiadas \(lines) líneas")
        case .info(let message), .failed(let message): return message
        }
    }
}
