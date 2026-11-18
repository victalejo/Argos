//
//  SSHCheckpoints.swift
//  ArgosCore
//
//  Puntos de restauración por el canal de comandos de la conexión compartida. Los
//  comandos los arma `CheckpointCommands`; la interpretación es de `CheckpointParser`.
//

import Foundation

extension SSHService {
    func runCheckpointCommand(_ command: String) async throws -> CheckpointCommandOutput {
        try RemoteCommandLimit.check(command)
        let result = try await run(command, timeout: .long)
        return CheckpointCommandOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }
}

extension SSHServicing {
    /// Por defecto (dobles de prueba): no disponible.
    func runCheckpointCommand(_ command: String) async throws -> CheckpointCommandOutput {
        throw CheckpointError.unavailable
    }
}

extension SessionsViewModel {
    /// Estado de Claude en la sesión del proyecto de `path` (para ofrecer «Ver lo que
    /// cambió en este turno» cuando termina).
    func claudeActivity(forProjectPath path: String) -> ClaudeActivity? {
        let sessions = projects.filter { $0.path == path }.map(\.sessionName)
        return claudeActivity.activity(forSessions: sessions)
    }
}
