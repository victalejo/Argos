//
//  WorkspacePollCommand.swift
//  ArgosCore
//
//  Una vuelta del sondeo de un servidor en UN solo comando (un solo canal SSH): estado de
//  Claude, lista de sesiones tmux y solicitudes de puertos de Claude, en secciones
//  separadas por marcadores (como el comando de recursos de `Monitor/`). Cada sección
//  reutiliza tal cual el comando que ya se lanzaba por separado, así el formato de los
//  hooks, de `@argos_claude` y de las solicitudes de `argos-ports` no cambia (lo comparten
//  iPhone/iPad y Android).
//
//  Salida (una línea por elemento; los marcadores llevan ':' y tmux no lo admite en un
//  nombre de sesión, así que no se confunden con datos):
//
//      @@argos-poll:claude
//      <pantalla>|<estado>|<pane_id>|<ventana>|<sesión>     (ver ClaudeActivitySnapshot)
//      @@argos-poll:sessions
//      <sesión>|<ventanas>|<adjunta>|<creada>              (ver TmuxSession(line:))
//      @@argos-poll:sessions-exit <código> <stderr en una línea>
//      @@argos-poll:ports
//      <hora del servidor> y `puerto<TAB>creada<TAB>nota`  (ver PortForwardRequestParser)
//      @@argos-poll:end
//
//  Una sección cuenta solo si llega completa (le sigue otro marcador): si el plazo remoto
//  corta el comando a medias, lo que falta se trata como «sin dato» y se conserva lo último.
//

import Foundation

/// Qué se pide en una vuelta.
enum WorkspacePollSection: String, CaseIterable, Sendable, Hashable {
    case claude
    case sessions
    case ports
}

/// Lista de sesiones leída en el sondeo.
enum SessionsPollResult: Equatable, Sendable {
    case sessions([TmuxSession])
    /// El servidor ya no tiene tmux: no se toca la lista (lo detecta la próxima carga).
    case tmuxMissing
    /// Fallo real de `tmux list-sessions` (código y mensaje).
    case failed(exitCode: Int, message: String)
}

/// Resultado de una vuelta. `nil` en un campo = no se pidió o no llegó completo.
struct WorkspacePollOutput: Equatable, Sendable {
    var claude: ClaudeActivitySnapshot?
    var sessions: SessionsPollResult?
    var portRequests: [PortForwardRequest]?

    init(claude: ClaudeActivitySnapshot? = nil, sessions: SessionsPollResult? = nil, portRequests: [PortForwardRequest]? = nil) {
        self.claude = claude
        self.sessions = sessions
        self.portRequests = portRequests
    }
}

enum WorkspacePollCommand {

    static let markerPrefix = "@@argos-poll:"
    static let sessionsExitMarker = markerPrefix + "sessions-exit"
    static let endMarker = markerPrefix + "end"

    static func marker(_ section: WorkspacePollSection) -> String {
        markerPrefix + section.rawValue
    }

    // MARK: - Comando

    /// Script POSIX sh de la vuelta (sin plazo: lo envuelve `RemoteTimeout.wrap`). Las
    /// secciones van separadas por `;`: que una falle no impide las demás.
    static func script(for sections: Set<WorkspacePollSection>) -> String {
        let parts = WorkspacePollSection.allCases.filter(sections.contains).map { section in
            "printf '%s\\n' '\(marker(section))'; " + body(of: section)
        }
        return (parts + ["printf '%s\\n' '\(endMarker)'"]).joined(separator: "; ")
    }

    private static func body(of section: WorkspacePollSection) -> String {
        switch section {
        case .claude:
            return "{ \(SSHService.claudeActivityCommand); }"
        case .sessions:
            // stdout (las sesiones) sale por el 3; stderr se guarda para clasificar el fallo
            // igual que `listSessions()` (sin servidor tmux, tmux ausente…).
            let list = "tmux list-sessions -F '\(SSHService.sessionFormat)'"
            return "{ e=$(\(list) 2>&1 >&3); s=$?; } 3>&1; "
                + "printf '%s %s %s\\n' '\(sessionsExitMarker)' \"$s\" \"$(printf '%s' \"$e\" | tr '\\n\\r' '  ')\""
        case .ports:
            return PortForwardServerFiles.listRequestsCommand
        }
    }

    // MARK: - Parser

    /// Interpreta la salida. Solo se rellenan las secciones pedidas y completas.
    static func parse(_ output: String, requested: Set<WorkspacePollSection>) -> WorkspacePollOutput {
        let sections = split(output)
        var result = WorkspacePollOutput()
        if requested.contains(.claude), let lines = sections[.claude] {
            result.claude = ClaudeActivitySnapshot(listPanesOutput: lines.joined(separator: "\n"))
        }
        if requested.contains(.sessions), let lines = sections[.sessions] {
            result.sessions = parseSessions(lines)
        }
        if requested.contains(.ports), let lines = sections[.ports] {
            result.portRequests = PortForwardRequestParser.parse(lines.joined(separator: "\n"))
        }
        return result
    }

    /// Líneas de cada sección COMPLETA (seguida de otro marcador).
    static func split(_ output: String) -> [WorkspacePollSection: [String]] {
        var complete: [WorkspacePollSection: [String]] = [:]
        var current: WorkspacePollSection?
        var lines: [String] = []
        for raw in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix(markerPrefix), !line.hasPrefix(sessionsExitMarker) {
                if let current { complete[current] = lines }
                current = WorkspacePollSection(rawValue: String(line.dropFirst(markerPrefix.count)))
                lines = []
            } else if current != nil {
                lines.append(line)
            }
        }
        return complete
    }

    /// Sesiones + línea de salida. Sin línea de salida (cortado a medias): sin dato.
    static func parseSessions(_ lines: [String]) -> SessionsPollResult? {
        guard let exitLine = lines.last(where: { $0.hasPrefix(sessionsExitMarker) }) else { return nil }
        let rest = exitLine.dropFirst(sessionsExitMarker.count).drop { $0 == " " }
        let code = Int(rest.prefix { $0 != " " }) ?? -1
        let stderr = String(rest.drop { $0 != " " }.dropFirst()).trimmingCharacters(in: .whitespaces)
        if code == 0 {
            let sessions = lines.filter { !$0.hasPrefix(sessionsExitMarker) }.compactMap(TmuxSession.init(line:))
            return .sessions(sessions)
        }
        if SSHService.indicatesNoTmuxServer(stdout: "", stderr: stderr) { return .sessions([]) }
        if SSHService.indicatesTmuxNotInstalled(stdout: "", stderr: stderr, exitCode: code) { return .tmuxMissing }
        return .failed(exitCode: code, message: stderr.isEmpty ? String(localized: "tmux list-sessions no devolvió detalles.") : stderr)
    }
}
