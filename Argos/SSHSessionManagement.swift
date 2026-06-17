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
            "tmux new-session -d -s \(Self.shellSingleQuoted(name))"
        )
    }

    /// Renombra una sesión (`tmux rename-session -t '<viejo>' '<nuevo>'`).
    func renameSession(from oldName: String, to newName: String) async throws {
        try await runManagementCommand(
            "tmux rename-session -t \(Self.shellSingleQuoted(oldName)) "
            + Self.shellSingleQuoted(newName)
        )
    }

    /// Mata una sesión (`tmux kill-session -t '<nombre>'`). Operación destructiva.
    func killSession(named name: String) async throws {
        try await runManagementCommand(
            "tmux kill-session -t \(Self.shellSingleQuoted(name))"
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
