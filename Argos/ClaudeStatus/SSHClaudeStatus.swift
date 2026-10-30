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
    ///
    /// settings.json puede contener secretos (p. ej. `env` con API keys), así que:
    ///  - el contenido viaja por SFTP, NUNCA en la línea de comandos (visible en `ps`);
    ///  - todo se crea bajo `umask 077`: temporal, copia `settings.json.argos-backup` y
    ///    el fichero final quedan en 600;
    ///  - la escritura es atómica (temporal + `mv`).
    func installClaudeHooks() async throws {
        let merged = ClaudeHookInstaller.installing(into: try await readClaudeSettings())
        let content = Data(try ClaudeHookInstaller.serialize(merged).utf8)

        // 1) Prepara (privado) y devuelve el $HOME absoluto para la ruta SFTP.
        let path = Self.claudeSettingsPath
        let prepared = try await runChecked([
            "umask 077",
            "mkdir -p \"$HOME/.claude\"",
            "{ [ ! -f \"\(path)\" ] || cp \"\(path)\" \"\(path).argos-backup\"; }",
            ": > \"\(path).argos-tmp\"",
            "printf '%s' \"$HOME\"",
        ].joined(separator: " && "))
        let home = prepared.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw SSHServiceError.commandFailed(exitCode: 0, message: "No se pudo resolver $HOME en el servidor.")
        }

        // 2) Contenido por SFTP sobre el temporal ya creado con permisos 600.
        _ = try await upload(data: content, toRemotePath: "\(home)/.claude/settings.json.argos-tmp")

        // 3) Reemplazo atómico.
        _ = try await runChecked("mv \"\(path).argos-tmp\" \"\(path)\"")
    }

    /// Ejecuta un comando y devuelve stdout; lanza `commandFailed` si sale con error.
    private func runChecked(_ command: String) async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? "No se pudo escribir ~/.claude/settings.json." : message
            )
        }
        return result.stdout
    }

    private func readClaudeSettings() async throws -> [String: Any] {
        let client = try await connectedClient()
        let result = try await capture(client, command: "cat \"\(Self.claudeSettingsPath)\" 2>/dev/null")
        // Inexistente (exit != 0, sin salida) cuenta como settings vacío.
        return try ClaudeHookInstaller.parseSettings(result.exitCode == 0 ? result.stdout : "")
    }
}
