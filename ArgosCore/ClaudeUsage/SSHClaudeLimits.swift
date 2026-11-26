//
//  SSHClaudeLimits.swift
//  ArgosCore
//
//  Poner o quitar la statusline de Argos que guarda los límites de uso de Claude (ver
//  `ClaudeLimitsInstaller`). `~/.claude/settings.json` se fusiona en Swift y se escribe
//  por SFTP, privado y con copia `.argos-backup`, como los hooks del indicador.
//

import Foundation

/// Estado de la statusline de límites en un servidor.
enum ClaudeLimitsInstallState: Equatable, Sendable {
    case inactive
    case active
    /// Está en settings.json pero falta el script o el comando anterior guardado (p. ej.
    /// settings.json copiado o sincronizado desde otro servidor).
    case needsRepair(previousMissing: Bool)
}

enum ClaudeLimitsError: LocalizedError, Equatable {
    case previousMissing
    case settingsChanged

    var errorDescription: String? {
        switch self {
        case .previousMissing:
            return String(localized: "Falta ~/.config/argos/statusline-previous en este servidor (¿settings.json copiado o sincronizado desde otro?), así que Argos no sabe cuál era tu barra de estado y no la toca. Quítala desde el servidor donde la activaste o restaura ~/.claude/settings.json.argos-backup.")
        case .settingsChanged:
            return String(localized: "~/.claude/settings.json cambió mientras Argos lo editaba (¿Claude Code o otro dispositivo?). No se modificó: vuelve a intentarlo.")
        }
    }
}

extension SSHService {

    private static let claudeSettingsPath = ".claude/settings.json"

    func claudeLimitsState() async throws -> ClaudeLimitsInstallState {
        let settings = try await readClaudeSettingsForLimits()
        guard ClaudeLimitsInstaller.isInstalled(in: settings) else { return .inactive }
        let previous = try await readHomeFile(ClaudeLimitsInstaller.previousRelativePath)
        let previousMissing = ClaudeLimitsInstaller.previousCommand(fromFile: previous) == nil
        let script = try await readHomeFile(ClaudeLimitsInstaller.scriptRelativePath)
        if previousMissing || script != ClaudeLimitsInstaller.script || !ClaudeLimitsInstaller.isCurrent(in: settings) {
            return .needsRepair(previousMissing: previousMissing)
        }
        return .active
    }

    /// Instala, actualiza o repara la statusline de Argos conservando la del usuario. Si ya
    /// estaba puesta, nunca inventa el comando anterior: solo reescribe el script.
    func installClaudeLimits() async throws {
        let before = try await readHomeFile(Self.claudeSettingsPath)
        let installation = ClaudeLimitsInstaller.installing(into: try ClaudeHookInstaller.parseSettings(before))
        // Primero el script y el comando anterior: la statusline nueva debe encontrarlos.
        try await writeHomeFilePrivately(Data(ClaudeLimitsInstaller.script.utf8), to: ClaudeLimitsInstaller.scriptRelativePath)
        if let previous = installation.previousCommand {
            let contents = ClaudeLimitsInstaller.previousFileContents(previous)
            try await writeHomeFilePrivately(Data(contents.utf8), to: ClaudeLimitsInstaller.previousRelativePath)
        }
        try await writeSettings(installation.settings, readAs: before)
    }

    /// Quita la statusline de Argos, devuelve la anterior y borra los límites guardados.
    func uninstallClaudeLimits() async throws {
        let before = try await readHomeFile(Self.claudeSettingsPath)
        let settings = try ClaudeHookInstaller.parseSettings(before)
        if ClaudeLimitsInstaller.isInstalled(in: settings) {
            let file = try await readHomeFile(ClaudeLimitsInstaller.previousRelativePath)
            guard let previous = ClaudeLimitsInstaller.previousCommand(fromFile: file) else {
                throw ClaudeLimitsError.previousMissing
            }
            try await writeSettings(ClaudeLimitsInstaller.removing(from: settings, previousCommand: previous), readAs: before)
        }
        _ = try await runChecked(
            "rm -f \"$HOME/\(ClaudeLimitsInstaller.limitsRelativePath)\"",
            failureMessage: String(localized: "No se pudieron borrar los límites guardados.")
        )
    }

    /// Escribe settings.json solo si no cambió desde que se leyó como `before` (lo relee
    /// justo antes: Claude Code u otro dispositivo pueden haberlo tocado entretanto).
    private func writeSettings(_ settings: [String: Any], readAs before: String) async throws {
        guard try await readHomeFile(Self.claudeSettingsPath) == before else { throw ClaudeLimitsError.settingsChanged }
        let content = Data(try ClaudeHookInstaller.serialize(settings).utf8)
        try await writeHomeFilePrivately(content, to: Self.claudeSettingsPath, backup: true)
    }

    private func readClaudeSettingsForLimits() async throws -> [String: Any] {
        try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.claudeSettingsPath))
    }
}
