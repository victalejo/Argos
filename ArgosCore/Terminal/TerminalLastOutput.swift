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

    /// Lo que se copia.
    struct Extracted: Equatable, Sendable {
        let text: String
        /// Solo la parte visible de la respuesta de Claude (empezó por encima).
        var isPartial = false
        /// Del transcript sin poder comprobarlo con la pantalla y con varias sesiones de
        /// Claude activas en la carpeta: puede ser de otra.
        var isUncertain = false
    }

    enum Failure: Error, Equatable {
        /// No se reconoce el prompt (o la respuesta de Claude).
        case notRecognized
        /// El último comando no escribió nada.
        case empty
        /// Claude sigue en su turno (o espera una elección).
        case inProgress
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
                    // Si el plazo mata el script a medias, el panel no se queda en modo copia.
                    "  c() { tmux -u send-keys -t \"$t\" -X cancel 2>/dev/null; }",
                    "  trap c EXIT",
                    "  trap 'c; trap - EXIT; exit 1' HUP INT TERM",
                    "  tmux -u send-keys -t \"$t\" -X history-bottom",
                    "  z=$(tmux -u display -p -t \"$t\" \"$f\")",
                    "  tmux -u send-keys -t \"$t\" -X previous-prompt -o 2>/dev/null",
                    "  a=$(tmux -u display -p -t \"$t\" \"$f\")",
                    "  tmux -u send-keys -t \"$t\" -X next-prompt 2>/dev/null",
                    "  b=$(tmux -u display -p -t \"$t\" \"$f\")",
                    "  c",
                    "  trap - EXIT HUP INT TERM",
                    "  printf '%s;%s;%s;%s\\n' \(rangeMarker(nonce)) \"$z\" \"$a\" \"$b\"",
                    "  printf '%s\\n' \(textMarker(nonce))",
                    "  tmux -u capture-pane -p -S -\(captureLines) -t \"$t\"",
                    "  exit 0",
                    "fi",
                ]
            }
        } else {
            // Claude Code: la carpeta del panel, para leer luego su transcript.
            lines.append(ClaudeTranscript.pathCommandLine(nonce: nonce))
        }
        lines += [
            "printf '%s\\n' \(textMarker(nonce))",
            "tmux -u capture-pane -p -J -S -\(captureLines) -t \"$t\"",
        ]
        return lines.joined(separator: "\n")
    }

    /// Lo que se copia, a partir de la salida de `command`.
    static func extract(_ output: String, kind: Kind, nonce: String) -> Result<Extracted, Failure> {
        var all = output.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        if kind == .claude { return claude(rows: rows(after: all, nonce: nonce), transcript: nil) }
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

    /// Claude Code: el transcript (`transcriptOutput`, salida de
    /// `ClaudeTranscript.readCommand`) si cuadra con la pantalla; si no, la pantalla.
    static func extractClaude(screenOutput: String, transcriptOutput: String?, nonce: String) -> Result<Extracted, Failure> {
        var all = screenOutput.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        let excerpt = transcriptOutput.flatMap { ClaudeTranscript.excerpt(in: $0, nonce: nonce) }
        return claude(rows: rows(after: all, nonce: nonce), transcript: excerpt)
    }

    /// Filas capturadas del panel (tras la marca de texto).
    private static func rows(after all: [String], nonce: String) -> [String] {
        all.firstIndex(of: textMarker(nonce)).map { Array(all[($0 + 1)...]) } ?? []
    }

    private static func claude(rows: [String], transcript: ClaudeTranscript.Excerpt?) -> Result<Extracted, Failure> {
        // A mitad de turno, lo último del transcript sería el turno anterior.
        if ClaudeResponseExtractor.isWorking(lines: rows) { return .failure(.inProgress) }
        let screen = ClaudeResponseExtractor.lastResponse(lines: rows)
        if let transcript, let text = ClaudeTranscript.lastAssistantText(transcript.lines) {
            if let screen {
                // Si la pantalla no muestra su final, es de otra sesión: manda la pantalla.
                guard ClaudeTranscript.appearsOnScreen(text, screen: rows) else {
                    return result(screen.text, isPartial: screen.isPartial)
                }
                return result(text)
            }
            var extracted = Extracted(text: text)
            extracted.isUncertain = (transcript.recentSessions ?? 0) > 1
            return .success(extracted)
        }
        guard let screen else { return .failure(.notRecognized) }
        return result(screen.text, isPartial: screen.isPartial)
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

    private static func heuristic(_ lines: [String], kind: Kind) -> Result<Extracted, Failure> {
        switch kind {
        case .shell:
            guard let text = ShellOutputExtractor.heuristicOutput(lines: lines) else { return .failure(.notRecognized) }
            return result(text)
        case .claude:
            return claude(rows: lines, transcript: nil)
        }
    }

    private static func result(_ text: String, isPartial: Bool = false) -> Result<Extracted, Failure> {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .failure(.empty)
            : .success(Extracted(text: text, isPartial: isPartial))
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
        /// Solo la parte visible de la respuesta de Claude.
        case copiedVisiblePart
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
            let extraction: Result<TerminalLastOutput.Extracted, TerminalLastOutput.Failure>
            if kind == .claude {
                let transcriptOutput = await transcript(for: output, nonce: nonce)
                extraction = TerminalLastOutput.extractClaude(screenOutput: output, transcriptOutput: transcriptOutput, nonce: nonce)
            } else {
                extraction = TerminalLastOutput.extract(output, kind: kind, nonce: nonce)
            }
            switch extraction {
            case .success(let extracted):
                copy(extracted.text)
                if extracted.isPartial {
                    show(.copiedVisiblePart)
                } else if extracted.isUncertain {
                    show(.info(String(localized: "Copiada la última respuesta de Claude, pero hay varias sesiones de Claude en esta carpeta: puede ser de otra.")))
                } else {
                    show(.copied(lines: extracted.text.components(separatedBy: "\n").count))
                }
            case .failure(.inProgress):
                show(.failed(String(localized: "Claude todavía está en su turno: espera a que termine para copiar su respuesta.")))
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

    /// Segundo paso con Claude: lee su transcript de la carpeta del panel. `nil` si no se
    /// sabe la carpeta o falla (se usa la pantalla).
    private func transcript(for screenOutput: String, nonce: String) async -> String? {
        let lines = screenOutput.components(separatedBy: "\n")
        guard let path = ClaudeTranscript.panePath(in: lines, nonce: nonce) else { return nil }
        let command = ClaudeTranscript.readCommand(keys: ClaudeTranscript.folderKeys(for: path), nonce: nonce)
        do {
            return try await run(command)
        } catch {
            Log.terminal.notice("No se pudo leer el transcript de Claude: \(error.userMessage, privacy: .public)")
            return nil
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
        case .copiedVisiblePart:
            return String(localized: "Copiada la parte visible de la última respuesta")
        case .info(let message), .failed(let message): return message
        }
    }
}
