//
//  SSHClaudeStatus.swift
//  Argos
//
//  Indicador de Claude Code por el CANAL DE COMANDOS: leer el estado de todos los
//  paneles (un solo `list-panes -a` por sondeo) e instalar los hooks en
//  `~/.claude/settings.json` del servidor. La fusión del JSON la hace
//  `ClaudeHookInstaller` aquí (en Swift), sin depender de python/jq en el servidor, y
//  el contenido se sube por SFTP (puede contener secretos).
//

import Foundation

extension SSHService {

    static let claudeActivityCommand =
        "tmux list-panes -a -F '#{\(ClaudeHookInstaller.option)}|#{window_index}|#{session_name}' 2>/dev/null"

    private static let claudeSettingsRelativePath = ".claude/settings.json"

    /// Estado de Claude en las sesiones del servidor. Sin servidor tmux -> vacío.
    func claudeActivity() async throws -> ClaudeActivitySnapshot {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.claudeActivityCommand)
        guard result.exitCode == 0 else { return .empty }
        return ClaudeActivitySnapshot(listPanesOutput: result.stdout)
    }

    /// ¿Están instalados los hooks de Argos en el settings.json del servidor?
    func claudeHooksInstalled() async throws -> Bool {
        ClaudeHookInstaller.isInstalled(in: try await readClaudeSettings())
    }

    /// Fusiona los hooks de Argos en `~/.claude/settings.json` (conserva lo demás).
    /// settings.json puede contener secretos (p. ej. `env` con API keys): se escribe con
    /// `writeHomeFilePrivately` (SFTP, permisos 600, atómico) y con copia `.argos-backup`.
    func installClaudeHooks() async throws {
        let merged = ClaudeHookInstaller.installing(into: try await readClaudeSettings())
        let content = Data(try ClaudeHookInstaller.serialize(merged).utf8)
        try await writeHomeFilePrivately(content, to: Self.claudeSettingsRelativePath, backup: true)
    }

    private func readClaudeSettings() async throws -> [String: Any] {
        // Inexistente cuenta como settings vacío.
        try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.claudeSettingsRelativePath))
    }
}
