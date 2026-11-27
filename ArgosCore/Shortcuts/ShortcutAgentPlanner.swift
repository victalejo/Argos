//
//  ShortcutAgentPlanner.swift
//  ArgosCore
//
//  Decisiones del atajo «Pedir a Claude en ‹proyecto›» (lógica pura, con tests): a qué
//  agente persistente del proyecto mandar el encargo (o si hay que crear uno), cuándo
//  pedir confirmación por el modo de permisos y cuándo negarse por memoria o por el tope
//  de agentes. La parte de red y de Atajos vive en `ArgosiOS/Shortcuts/`.
//

import Foundation

/// Qué hará el atajo con el encargo.
enum ShortcutAgentPlan: Equatable, Sendable {
    /// Agente del proyecto en marcha: se le escribe sin arrancar nada.
    case reuse(PersistentAgentInfo)
    /// Agente del proyecto parado o en reposo: se reanuda (arranca un `claude`) y se le escribe.
    case resume(PersistentAgentInfo)
    /// El proyecto no tiene agentes: se crea uno con el modo de los ajustes.
    case create(ClaudeAgentCommand.PermissionMode)

    /// Arranca un `claude` nuevo en el servidor (cuenta para la guardia de memoria).
    var startsClaude: Bool {
        if case .reuse = self { return false }
        return true
    }

    /// Modo de permisos con el que trabajará el agente; `nil` si su `meta.json` trae uno
    /// que esta versión no reconoce (se trata como el más peligroso: se confirma).
    var permissionMode: ClaudeAgentCommand.PermissionMode? {
        switch self {
        case .reuse(let info), .resume(let info):
            return ShortcutAgentPlanner.declaredMode(of: info.meta)
        case .create(let mode):
            return mode
        }
    }
}

enum ShortcutAgentPlanner {

    /// Agente al que mandar el encargo: el más reciente EN MARCHA del proyecto (no arranca
    /// nada); si no hay, el más reciente parado o en reposo (se reanuda); si el proyecto no
    /// tiene agentes, se crea uno con `newAgentMode`.
    static func plan(
        agents: [PersistentAgentInfo],
        workingDirectory: String,
        newAgentMode: ClaudeAgentCommand.PermissionMode
    ) -> ShortcutAgentPlan {
        let folder = normalized(workingDirectory)
        let mine = agents
            .filter { normalized($0.meta.workingDirectory) == folder }
            .sorted { $0.meta.createdAt > $1.meta.createdAt }
        if let alive = mine.first(where: { $0.isAlive && !$0.meta.isHibernated }) { return .reuse(alive) }
        if let latest = mine.first { return .resume(latest) }
        return .create(newAgentMode)
    }

    /// Modo que declara el `meta.json`: `nil` si trae uno desconocido. Sin modo guardado
    /// (agentes antiguos) se crearon preguntando cada permiso.
    static func declaredMode(of meta: PersistentAgentMeta) -> ClaudeAgentCommand.PermissionMode? {
        declaredMode(raw: meta.permissionMode)
    }

    static func declaredMode(raw: String?) -> ClaudeAgentCommand.PermissionMode? {
        guard let raw else { return .default }
        return ClaudeAgentCommand.PermissionMode(rawValue: raw)
    }

    /// Hay que confirmar antes de enviar: el agente actuará sin preguntar (o con un modo
    /// desconocido), salvo que el usuario lo haya permitido en Ajustes.
    static func requiresConfirmation(mode: ClaudeAgentCommand.PermissionMode?, allowsUnconfirmed: Bool) -> Bool {
        guard !allowsUnconfirmed else { return false }
        switch mode {
        case .bypassPermissions, .acceptEdits, nil: return true
        case .default, .plan: return false
        }
    }

    /// Texto del modo para la confirmación.
    static func modeTitle(_ mode: ClaudeAgentCommand.PermissionMode?) -> String {
        mode?.title ?? String(localized: "Desconocido")
    }

    /// Motivo para NO arrancar un `claude` (memoria o tope), o `nil` si se puede. A
    /// diferencia de la app, el atajo no deja «crear de todos modos»: no hay a quién preguntar.
    static func capacityRefusal(plan: ShortcutAgentPlan, freeMemoryKB: Int?, liveAgents: Int) -> String? {
        guard plan.startsClaude else { return nil }
        guard case .warning(let title, let message) = AgentLaunchGuard.assess(
            freeMemoryKB: freeMemoryKB, liveAgents: liveAgents
        ) else { return nil }
        return String(localized: "\(title). \(message) El atajo no ha arrancado otro agente.")
    }

    /// Las rutas se comparan sin la barra final («/srv/app/» es «/srv/app»).
    static func normalized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

/// Encargo que llega por el atajo, ya validado.
enum ShortcutTask {
    /// Tope razonable (Atajos puede pasar el contenido de un archivo entero).
    static let maxCharacters = 20_000

    static func validated(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ShortcutError.emptyTask }
        guard text.count <= maxCharacters else { throw ShortcutError.taskTooLong(maxCharacters) }
        return text
    }
}

/// Preferencias de los atajos (en el dispositivo).
enum ShortcutPreferences {
    /// «Permitir atajos sin confirmar» (desactivado por defecto).
    static let allowsUnconfirmedKey = "shortcuts.allowsUnconfirmed"

    static func allowsUnconfirmed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: allowsUnconfirmedKey)
    }
}

/// Errores de los atajos, con el mensaje que verá el usuario en Atajos o Siri.
enum ShortcutError: LocalizedError, Equatable {
    case emptyTask
    case taskTooLong(Int)
    case serverNotFound
    case projectNotFound
    case timedOut
    case claudeMissing
    case claudeLoggedOut
    case capacity(String)
    case sendFailed(String)
    /// El agente elegido ya no está (o trabaja en otra carpeta) al ir a entregar.
    case agentChanged
    /// Su modo de permisos cambió desde que se confirmó.
    case permissionModeChanged
    /// La app está bloqueada con Face ID y no se pudo (o no se quiso) desbloquear.
    case appLocked
    /// El encargo guardado elegido ya no está en la biblioteca del servidor.
    case promptNotFound

    var errorDescription: String? {
        switch self {
        case .emptyTask:
            return String(localized: "El encargo está vacío: escribe qué quieres que haga Claude.")
        case .taskTooLong(let limit):
            return String(localized: "El encargo es demasiado largo (máximo \(String(limit)) caracteres).")
        case .serverNotFound:
            return String(localized: "Ese servidor ya no está en Argos. Elige otro proyecto.")
        case .projectNotFound:
            return String(localized: "No se encontró ese proyecto. Abre Argos y entra en su servidor para actualizar la lista.")
        case .timedOut:
            return String(localized: "El servidor no respondió a tiempo. Comprueba la conexión o abre Argos para ver qué pasa.")
        case .claudeMissing:
            return String(localized: "Claude Code no está instalado en el servidor. Instálalo desde Argos.")
        case .claudeLoggedOut:
            return String(localized: "El servidor no tiene sesión de Claude. Conéctala desde Argos (Agentes → Conectar Claude).")
        case .capacity(let message):
            return message
        case .sendFailed(let message):
            return String(localized: "No se pudo enviar el encargo: \(message)")
        case .agentChanged:
            return String(localized: "El agente de este proyecto cambió mientras se preparaba el envío. Vuelve a ejecutar el atajo.")
        case .permissionModeChanged:
            return String(localized: "El modo de permisos de este agente cambió; ábrelo en Argos para confirmarlo.")
        case .appLocked:
            return String(localized: "Argos está bloqueado. Desbloquéalo para usar este atajo.")
        case .promptNotFound:
            return String(localized: "Ese encargo guardado ya no está en la biblioteca del proyecto. Elige otro en el atajo.")
        }
    }
}
