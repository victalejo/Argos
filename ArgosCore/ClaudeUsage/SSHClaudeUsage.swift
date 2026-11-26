//
//  SSHClaudeUsage.swift
//  ArgosCore
//
//  Lanzar y leer el índice de uso de tokens de Claude en el servidor (ver
//  `ClaudeUsageIndex`). Solo lee los .jsonl del usuario y escribe en ~/.config/argos/usage.
//

import Foundation

extension SSHService {

    /// Pone el script al día y lo lanza en segundo plano (vuelve enseguida).
    func startClaudeUsageIndex() async throws {
        let installed = try await readHomeFile(ClaudeUsageIndex.scriptRelativePath)
        if installed != ClaudeUsageIndex.script {
            try await writeHomeFilePrivately(Data(ClaudeUsageIndex.script.utf8), to: ClaudeUsageIndex.scriptRelativePath)
        }
        _ = try await runChecked(
            ClaudeUsageIndex.startCommand,
            failureMessage: String(localized: "No se pudo calcular el uso de Claude en el servidor.")
        )
    }

    func readClaudeUsage() async throws -> ClaudeUsageSnapshot {
        let output = try await runChecked(
            RemoteTimeout.wrap(ClaudeUsageIndex.readCommand),
            failureMessage: String(localized: "No se pudo leer el uso de Claude del servidor.")
        )
        return ClaudeUsageSnapshot(output: output)
    }
}
