//
//  SSHClaudeStatus.swift
//  Argos
//
//  Indicador de Claude Code por el CANAL DE COMANDOS: leer el estado de todos los
//  paneles (un solo `list-panes -a` por sondeo) e instalar los hooks en
//  `~/.claude/settings.json` del servidor. La fusión del JSON la hace
//  `ClaudeHookInstaller` aquí (en Swift), sin depender de python/jq en el servidor.
//

import Foundation

extension SSHService {

    static let claudeActivityCommand =
        "tmux list-panes -a -F '#{\(ClaudeHookInstaller.option)}|#{window_index}|#{session_name}' 2>/dev/null"

    private static let claudeSettingsPath = "$HOME/.claude/settings.json"

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
    /// Deja una copia en `settings.json.argos-backup` y escribe de forma atómica
    /// (fichero temporal + `mv`). El contenido viaja en base64: sin problemas de quoting.
    func installClaudeHooks() async throws {
        let merged = ClaudeHookInstaller.installing(into: try await readClaudeSettings())
        let encoded = Data(try ClaudeHookInstaller.serialize(merged).utf8).base64EncodedString()
        let path = Self.claudeSettingsPath
        let command = [
            "mkdir -p \"$HOME/.claude\"",
            "{ [ ! -f \"\(path)\" ] || cp \"\(path)\" \"\(path).argos-backup\"; }",
            "printf '%s' '\(encoded)' | base64 -d > \"\(path).argos-tmp\"",
            "mv \"\(path).argos-tmp\" \"\(path)\"",
        ].joined(separator: " && ")

        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? "No se pudo escribir ~/.claude/settings.json." : message
            )
        }
    }

    private func readClaudeSettings() async throws -> [String: Any] {
        let client = try await connectedClient()
        let result = try await capture(client, command: "cat \"\(Self.claudeSettingsPath)\" 2>/dev/null")
        // Inexistente (exit != 0, sin salida) cuenta como settings vacío.
        return try ClaudeHookInstaller.parseSettings(result.exitCode == 0 ? result.stdout : "")
    }
}
