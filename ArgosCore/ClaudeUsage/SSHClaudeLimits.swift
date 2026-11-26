//
//  SSHClaudeLimits.swift
//  ArgosCore
//
//  Poner o quitar la statusline de Argos que guarda los límites de uso de Claude (ver
//  `ClaudeLimitsInstaller`). `~/.claude/settings.json` se fusiona en Swift y se escribe
//  por SFTP, privado y con copia `.argos-backup`, como los hooks del indicador.
//

import Foundation

extension SSHService {

    private static let claudeSettingsPath = ".claude/settings.json"

    /// ¿Está puesta la statusline de Argos en el servidor?
    func claudeLimitsInstalled() async throws -> Bool {
        ClaudeLimitsInstaller.isInstalled(in: try await readClaudeSettingsForLimits())
    }

    /// Instala (o actualiza) la statusline de Argos conservando la del usuario.
    func installClaudeLimits() async throws {
        let settings = try await readClaudeSettingsForLimits()
        let installation = ClaudeLimitsInstaller.installing(into: settings)
        // Primero el script y el comando anterior: la statusline nueva debe encontrarlos.
        try await writeHomeFilePrivately(Data(ClaudeLimitsInstaller.script.utf8), to: ClaudeLimitsInstaller.scriptRelativePath)
        if let previous = installation.previousCommand {
            try await writeHomeFilePrivately(Data(previous.utf8), to: ClaudeLimitsInstaller.previousRelativePath)
        }
        let content = Data(try ClaudeHookInstaller.serialize(installation.settings).utf8)
        try await writeHomeFilePrivately(content, to: Self.claudeSettingsPath, backup: true)
    }

    /// Quita la statusline de Argos y devuelve la anterior.
    func uninstallClaudeLimits() async throws {
        let settings = try await readClaudeSettingsForLimits()
        guard ClaudeLimitsInstaller.isInstalled(in: settings) else { return }
        let previous = try await readHomeFile(ClaudeLimitsInstaller.previousRelativePath)
        let restored = ClaudeLimitsInstaller.removing(from: settings, previousCommand: previous)
        let content = Data(try ClaudeHookInstaller.serialize(restored).utf8)
        try await writeHomeFilePrivately(content, to: Self.claudeSettingsPath, backup: true)
    }

    private func readClaudeSettingsForLimits() async throws -> [String: Any] {
        try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.claudeSettingsPath))
    }
}
