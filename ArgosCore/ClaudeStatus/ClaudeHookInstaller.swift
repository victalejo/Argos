//
//  ClaudeHookInstaller.swift
//  Argos
//
//  Fusión (lógica pura) de los hooks de Argos en `~/.claude/settings.json` del
//  servidor. Los hooks escriben el estado de Claude en la opción de panel de tmux
//  `@argos_claude` usando `$TMUX_PANE` (heredado por los hooks del proceso `claude`).
//  Fuera de tmux no hacen nada. Siempre salen con 0 y sin stdout, así que nunca
//  bloquean ni alteran a Claude (p. ej. `PermissionRequest` sigue su flujo normal).
//
//  Se identifican por `marker` en el comando: instalar primero quita los de Argos
//  (idempotente / actualizable) y nunca toca los hooks propios del usuario.
//

import Foundation

enum ClaudeHookError: LocalizedError, Equatable {
    case invalidSettings

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "~/.claude/settings.json del servidor no es un JSON válido; no se modificó. "
                 + "Corrígelo y vuelve a intentarlo."
        }
    }
}

enum ClaudeHookInstaller {

    /// Marca que identifica los hooks instalados por Argos.
    static let marker = "argos-claude-status"
    /// Opción de panel de tmux donde se guarda el estado.
    static let option = "@argos_claude"

    /// Evento de Claude Code -> (matcher opcional, estado a escribir; `nil` = borrar).
    private static let entries: [(event: String, matcher: String?, state: ClaudeActivity?)] = [
        ("UserPromptSubmit", nil, .working),
        ("PostToolUse", nil, .working),
        // Sin estos, una herramienta que falla tras aprobarla (o un permiso denegado en
        // modo auto) dejaba el panel «esperando» hasta el final del turno.
        ("PostToolUseFailure", nil, .working),
        ("PermissionDenied", nil, .working),
        // También AskUserQuestion / ExitPlanMode, incluso en bypassPermissions.
        ("PermissionRequest", nil, .waiting),
        ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", .waiting),
        ("Stop", nil, .done),
        // Un error de la API corta el turno SIN `Stop`: se quedaba «trabajando».
        ("StopFailure", nil, .done),
        ("SessionEnd", nil, nil),
    ]
    // Interrumpir con Esc no dispara ningún hook: lo corrige el sondeo mirando la
    // pantalla (`ClaudeScreenSignal`).

    /// Comando del hook. Sin `$TMUX_PANE` (Claude fuera de tmux) no hace nada.
    static func command(setting state: ClaudeActivity?) -> String {
        let action = state.map { "set-option -p -t \"$TMUX_PANE\" \(option) \($0.rawValue)" }
            ?? "set-option -pu -t \"$TMUX_PANE\" \(option)"
        return "[ -n \"$TMUX_PANE\" ] && tmux \(action) >/dev/null 2>&1; exit 0 # \(marker)"
    }

    // MARK: - (De)serialización

    /// Vacío -> `[:]`. JSON inválido o que no sea un objeto -> `.invalidSettings`.
    static func parseSettings(_ text: String) throws -> [String: Any] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { throw ClaudeHookError.invalidSettings }
        return dictionary
    }

    static func serialize(_ settings: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Fusión

    /// ¿Están todos los hooks de Argos presentes y en su versión ACTUAL (mismo comando
    /// y matcher)? Una versión antigua cuenta como no instalada, para actualizarla.
    static func isInstalled(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return entries.allSatisfy { entry in
            groups(hooks[entry.event]).contains { group in
                group["matcher"] as? String == entry.matcher
                    && handlers(group).contains { $0["command"] as? String == command(setting: entry.state) }
            }
        }
    }

    /// ¿Hay ALGÚN hook de Argos (de cualquier versión)? Indica que el usuario ya activó
    /// el indicador, así que se puede actualizar sin volver a preguntar.
    static func hasAnyOurs(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { value in
            groups(value).contains { handlers($0).contains(where: isOurs) }
        }
    }

    /// Devuelve `settings` con los hooks de Argos (re)instalados.
    static func installing(into settings: [String: Any]) -> [String: Any] {
        var result = removing(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for entry in entries {
            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": command(setting: entry.state),
                    "timeout": 5,
                ] as [String: Any]],
            ]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            hooks[entry.event] = groups(hooks[entry.event]) + [group]
        }
        result["hooks"] = hooks
        return result
    }

    /// Devuelve `settings` sin los hooks de Argos (conserva los del usuario).
    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let eventGroups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = eventGroups.compactMap { group in
                let original = handlers(group)
                let kept = original.filter { !isOurs($0) }
                if kept.count == original.count { return group }   // grupo ajeno: intacto
                guard !kept.isEmpty else { return nil }            // solo tenía los nuestros
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        var result = settings
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    private static func groups(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func handlers(_ group: [String: Any]) -> [[String: Any]] {
        group["hooks"] as? [[String: Any]] ?? []
    }

    private static func isOurs(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(marker) ?? false
    }
}
