//
//  CheckpointHookInstaller.swift
//  ArgosCore
//
//  Hook de los puntos de restauración en `~/.claude/settings.json` (lógica pura). Es
//  APARTE de los del indicador (`ClaudeHookInstaller`): lleva su propio marcador, así que
//  instalar, actualizar o quitar el indicador (aquí, en el iPhone o en Android, incluidas
//  las versiones publicadas) ni lo añade ni lo toca, y la instalación normal produce
//  exactamente el mismo settings.json que antes de existir esta función. Solo se añade
//  cuando el usuario activa los puntos de restauración en un proyecto de ese servidor.
//

import Foundation

enum CheckpointHookInstaller {

    /// Marca del hook. NO contiene `ClaudeHookInstaller.marker`.
    static let marker = "argos-checkpoint"
    static let event = "UserPromptSubmit"
    /// Plazo del hook: el script se limita a sí mismo (unos segundos) y Claude lo corta aquí.
    static let timeout = 15

    /// Ejecuta el script instalado (si está) sin dejar salir nada por stdout (en
    /// `UserPromptSubmit`, Claude lo añadiría como contexto) y siempre con éxito (un código
    /// 2 bloquearía el mensaje).
    static var command: String {
        "f=\"$HOME/\(CheckpointScript.installedRelativePath)\"; [ -f \"$f\" ] && sh \"$f\" hook >/dev/null 2>&1; exit 0 # \(marker)"
    }

    /// ¿Está el hook en su versión actual?
    static func isInstalled(in settings: [String: Any]) -> Bool {
        groups(settings)[event, default: []].contains { group in
            group["matcher"] == nil && handlers(group).contains { $0["command"] as? String == command }
        }
    }

    /// ¿Hay algún hook de puntos (de cualquier versión)? El usuario ya lo activó.
    static func hasAny(in settings: [String: Any]) -> Bool {
        groups(settings).values.contains { $0.contains { handlers($0).contains(where: isOurs) } }
    }

    /// `settings` con el hook (re)instalado; conserva todo lo demás.
    static func installing(into settings: [String: Any]) -> [String: Any] {
        var result = removing(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout] as [String: Any]]]
        hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        result["hooks"] = hooks
        return result
    }

    /// `settings` sin el hook de puntos (conserva los del indicador y los del usuario).
    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (name, value) in hooks {
            guard let eventGroups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = eventGroups.compactMap { group in
                let original = handlers(group)
                let kept = original.filter { !isOurs($0) }
                if kept.count == original.count { return group }
                guard !kept.isEmpty else { return nil }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            hooks[name] = cleaned.isEmpty ? nil : cleaned
        }
        var result = settings
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    private static func groups(_ settings: [String: Any]) -> [String: [[String: Any]]] {
        (settings["hooks"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [[String: Any]] }
    }

    private static func handlers(_ group: [String: Any]) -> [[String: Any]] {
        group["hooks"] as? [[String: Any]] ?? []
    }

    private static func isOurs(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.hasSuffix("# \(marker)") ?? false
    }
}
