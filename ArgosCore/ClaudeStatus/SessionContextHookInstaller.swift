//
//  SessionContextHookInstaller.swift
//  ArgosCore
//
//  Hook `SessionStart` de Argos en `~/.claude/settings.json` (lógica pura): ejecuta
//  `SessionContextScript` y su salida le llega a Claude como contexto al arrancar. Va
//  APARTE de los del indicador (`ClaudeHookInstaller`), con su propio marcador: instalar,
//  actualizar o quitar el indicador (aquí, en el iPhone o en Android, incluidas las
//  versiones publicadas) no lo toca, y las versiones viejas no saben que existe.
//

import Foundation

enum SessionContextHookInstaller {

    /// Marca del hook. NO contiene `ClaudeHookInstaller.marker` ni el de los puntos.
    static let marker = "argos-session-context"
    static let event = "SessionStart"
    /// Al abrir, reanudar, `/clear` y tras compactar (no en `fork`, que hereda el contexto).
    static let matcher = "startup|resume|clear|compact"
    /// Plazo del hook en Claude Code: el script se corta solo a los ~2,5 s.
    static let timeout = 5

    /// Ejecuta el script instalado (si está). Su stdout ES el contexto; stderr se descarta
    /// y siempre sale con 0 (otro código mostraría un error al usuario).
    static var command: String {
        "f=\"$HOME/\(SessionContextScript.installedRelativePath)\"; [ -f \"$f\" ] && sh \"$f\" 2>/dev/null; exit 0 # \(marker)"
    }

    /// ¿Está el hook en su versión actual?
    static func isInstalled(in settings: [String: Any]) -> Bool {
        groups(settings)[event, default: []].contains { group in
            group["matcher"] as? String == matcher && handlers(group).contains { $0["command"] as? String == command }
        }
    }

    /// ¿Hay algún hook de contexto (de cualquier versión)?
    static func hasAny(in settings: [String: Any]) -> Bool {
        groups(settings).values.contains { $0.contains { handlers($0).contains(where: isOurs) } }
    }

    /// `settings` con el hook (re)instalado, una sola vez; conserva todo lo demás.
    static func installing(into settings: [String: Any]) -> [String: Any] {
        var result = removing(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
        let group: [String: Any] = ["matcher": matcher, "hooks": [handler]]
        hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        result["hooks"] = hooks
        return result
    }

    /// `settings` sin el hook de contexto (conserva los demás de Argos y los del usuario).
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

/// Estado del contexto al arrancar en un servidor.
struct SessionContextStatus: Equatable, Sendable {
    let hookInstalled: Bool
    let scriptPresent: Bool
    /// El usuario lo apagó (`session-context.off`).
    let turnedOff: Bool

    var isEnabled: Bool { hookInstalled && scriptPresent && !turnedOff }
    /// Nadie lo activó ni lo apagó aquí (servidores con el indicador de antes de esta
    /// función): la app lo ofrece una vez en lugar de activarlo sola.
    var isUndecided: Bool { !hookInstalled && !turnedOff }
}
