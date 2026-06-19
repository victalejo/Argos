//
//  SSHSessionManagement.swift
//  Argos
//
//  Fase 3: gestión de sesiones tmux (crear / renombrar / matar) por el CANAL DE
//  COMANDOS (executeCommandStream), NO por el PTY. Cada operación es un único comando
//  tmux no interactivo; la UI refresca la lista después de cualquiera de ellas.
//
//  Los nombres se entrecomillan para el shell con `Self.shellSingleQuoted(_:)`
//  (definido en SSHTerminalSession.swift) para resistir espacios y caracteres
//  especiales. La validación de caracteres prohibidos por tmux (':' y '.') la hace
//  `SessionNameValidator` antes de llegar aquí.
//

import Foundation
import Citadel
import NIOCore

extension SSHService {

    /// Crea una nueva sesión tmux *detached* (`tmux new-session -d -s '<nombre>'`).
    func createSession(named name: String) async throws {
        try await runManagementCommand(
            "tmux new-session -d -s \(ShellQuoting.singleQuoted(name))"
        )
    }

    /// Renombra una sesión (`tmux rename-session -t '<viejo>' '<nuevo>'`).
    func renameSession(from oldName: String, to newName: String) async throws {
        try await runManagementCommand(
            "tmux rename-session -t \(ShellQuoting.singleQuoted(oldName)) "
            + ShellQuoting.singleQuoted(newName)
        )
    }

    /// Mata una sesión (`tmux kill-session -t '<nombre>'`). Operación destructiva.
    func killSession(named name: String) async throws {
        try await runManagementCommand(
            "tmux kill-session -t \(ShellQuoting.singleQuoted(name))"
        )
    }

    // MARK: - Ventanas

    /// Lista las ventanas de una sesión. Devuelve `[]` si la sesión no existe o no hay
    /// servidor tmux (no lanza: la barra de ventanas simplemente queda vacía).
    func listWindows(session: String) async throws -> [TmuxWindow] {
        let client = try await connectedClient()
        let command =
            "tmux list-windows -t \(ShellQuoting.singleQuoted(session)) "
            + "-F '#{window_index}|#{window_name}|#{window_active}|#{window_panes}'"
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { TmuxWindow(line: String($0)) }
            .sorted { $0.index < $1.index }
    }

    /// Cambia la ventana activa de la sesión (`tmux select-window -t '<sesión>':<idx>`).
    /// El terminal adjunto a esa sesión refleja el cambio en vivo.
    func selectWindow(session: String, index: Int) async throws {
        try await runManagementCommand(
            "tmux select-window -t \(ShellQuoting.singleQuoted(session)):\(index)"
        )
    }

    /// Crea una nueva ventana en la sesión (`tmux new-window -t '<sesión>'`).
    func newWindow(session: String) async throws {
        try await runManagementCommand(
            "tmux new-window -t \(ShellQuoting.singleQuoted(session))"
        )
    }

    /// Ejecuta un comando de gestión y lanza `commandFailed` si tmux sale con código
    /// distinto de cero (p. ej. nombre duplicado o sesión inexistente), propagando el
    /// mensaje de stderr de tmux para mostrarlo en la UI.
    private func runManagementCommand(_ command: String) async throws {
        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: detail.isEmpty ? "tmux no devolvió detalles." : detail
            )
        }
    }
}
