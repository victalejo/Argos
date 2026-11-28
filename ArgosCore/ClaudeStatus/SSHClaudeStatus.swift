//
//  SSHClaudeStatus.swift
//  Argos
//
//  Indicador de Claude Code por el CANAL DE COMANDOS: leer el estado de todos los
//  paneles (un solo comando por sondeo, ver `claudeActivityCommand`) e instalar los hooks en
//  `~/.claude/settings.json` del servidor. La fusión del JSON la hace
//  `ClaudeHookInstaller` aquí (en Swift), sin depender de python/jq en el servidor, y
//  el contenido se sube por SFTP (puede contener secretos).
//

import Foundation

extension SSHService {

    /// Un `list-panes -a` y, SOLO en los paneles working/waiting/done, un vistazo a su
    /// pantalla (ver `ClaudeScreenSignal`): `2` si el pie dice «esc to interrupt» o hay
    /// subagentes en segundo plano (`✻ Waiting for 1 background agent to finish`: el
    /// hook `Stop` ya saltó pero sigue trabajando), `1` si hay línea de spinner
    /// (`… (12s`), `0` si nada, `-` si no se miró. Debe valer en sh y zsh (shell de
    /// login del servidor): por eso `[|]` y no `|` en patrones.
    static let claudeActivityCommand = """
        tmux -u list-panes -a -F '#{\(ClaudeHookInstaller.option)}|#{pane_id}|#{window_index}|#{session_name}' 2>/dev/null \
        | while IFS= read -r l; do s=${l%%[|]*}; r=${l#*[|]}; p=${r%%[|]*}; c=-; \
        if [ "$s" = working ] || [ "$s" = waiting ] || [ "$s" = done ]; then \
        t=$(tmux -u capture-pane -p -t "$p" 2>/dev/null | grep -v '^[[:space:]]*$'); c=0; \
        printf '%s\\n' "$t" | grep -q '… ([0-9]' && c=1; \
        printf '%s\\n' "$t" | tail -n 4 | grep -q 'esc to interrupt' && c=2; \
        printf '%s\\n' "$t" | grep -q '^[^ ]* Waiting for [0-9]* background' && c=2; \
        fi; printf '%s|%s\\n' "$c" "$l"; done
        """

    private static let claudeSettingsRelativePath = ".claude/settings.json"

    /// Estado de Claude en las sesiones del servidor. Sin servidor tmux -> vacío.
    func claudeActivity() async throws -> ClaudeActivitySnapshot {
        let client = try await connectedClient()
        let result = try await capture(client, command: RemoteTimeout.wrap(Self.claudeActivityCommand))
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
    /// En un servidor que aún no tenía el indicador va con él, salvo que el usuario lo
    /// apagara, el contexto al arrancar (`SSHSessionContext`).
    func installClaudeHooks() async throws {
        var settings = try await readClaudeSettings()
        if !ClaudeHookInstaller.hasAnyOurs(in: settings), await prepareSessionContextForNewInstall() {
            // El script ya está subido: se relee settings.json y va el hook con el indicador.
            settings = SessionContextHookInstaller.installing(into: try await readClaudeSettings())
        }
        let merged = ClaudeHookInstaller.installing(into: settings)
        let content = Data(try ClaudeHookInstaller.serialize(merged).utf8)
        try await writeHomeFilePrivately(content, to: Self.claudeSettingsRelativePath, backup: true)
    }

    /// Si el indicador ya se activó con una versión anterior de los hooks, los
    /// actualiza (sin preguntar: el usuario ya dio su permiso). Devuelve si escribió.
    @discardableResult
    func upgradeClaudeHooksIfOutdated() async throws -> Bool {
        // El de los puntos de restauración, solo donde el usuario ya lo activó.
        try await upgradeCheckpointHookIfOutdated()
        // El contexto al arrancar: solo donde ya estaba activado (nunca lo activa).
        let contextWritten = try await upgradeSessionContextIfOutdated()
        let settings = try await readClaudeSettings()
        guard ClaudeHookInstaller.hasAnyOurs(in: settings),
              !ClaudeHookInstaller.isInstalled(in: settings)
        else { return contextWritten }
        let merged = ClaudeHookInstaller.installing(into: settings)
        let content = Data(try ClaudeHookInstaller.serialize(merged).utf8)
        try await writeHomeFilePrivately(content, to: Self.claudeSettingsRelativePath, backup: true)
        return true
    }

    private func readClaudeSettings() async throws -> [String: Any] {
        // Inexistente cuenta como settings vacío.
        try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.claudeSettingsRelativePath))
    }
}
