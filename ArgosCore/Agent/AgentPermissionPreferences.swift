//
//  AgentPermissionPreferences.swift
//  Argos
//
//  Modo de permisos con el que arrancan los agentes: el del proyecto si se eligió uno,
//  si no el de Ajustes y, sin nada configurado, todos los permisos. Se guarda en este
//  dispositivo; nunca en `projects.json`, que comparten los demás clientes.
//

import Foundation

extension ClaudeAgentCommand.PermissionMode {
    var title: String {
        switch self {
        case .bypassPermissions: return "Todos los permisos"
        case .acceptEdits: return "Aceptar ediciones"
        case .default: return "Preguntar siempre"
        case .plan: return "Solo planificar"
        }
    }

    var detail: String {
        switch self {
        case .bypassPermissions: return "Ejecuta cualquier acción sin preguntar. Si el usuario del servidor es root, Claude no lo permite y se pregunta cada acción."
        case .acceptEdits: return "Edita archivos sin preguntar y pide permiso para lo demás."
        case .default: return "Pide permiso antes de cada acción que no esté aprobada."
        case .plan: return "Explora y propone cambios sin modificar nada."
        }
    }

    var symbolName: String {
        switch self {
        case .bypassPermissions: return "bolt.shield"
        case .acceptEdits: return "pencil.circle"
        case .default: return "hand.raised"
        case .plan: return "doc.text.magnifyingglass"
        }
    }
}

enum AgentPermissionPreferences {

    static let fallback = ClaudeAgentCommand.PermissionMode.bypassPermissions
    /// Sin puntos: `UserDefaults` observa las claves como rutas KVO.
    static let globalKey = "agentPermissionMode"
    /// Valor guardado en un proyecto que sigue el ajuste global.
    static let useGlobalChoice = ""

    /// La ruta va en base64 porque suele llevar puntos.
    static func projectKey(serverID: UUID, workingDirectory: String) -> String {
        let path = Data(workingDirectory.utf8).base64EncodedString()
        return "\(globalKey):\(serverID.uuidString):\(path)"
    }

    static func globalMode(defaults: UserDefaults = .standard) -> ClaudeAgentCommand.PermissionMode {
        defaults.string(forKey: globalKey).flatMap(ClaudeAgentCommand.PermissionMode.init(rawValue:)) ?? fallback
    }

    static func effectiveMode(
        serverID: UUID,
        workingDirectory: String,
        defaults: UserDefaults = .standard
    ) -> ClaudeAgentCommand.PermissionMode {
        let key = projectKey(serverID: serverID, workingDirectory: workingDirectory)
        return defaults.string(forKey: key).flatMap(ClaudeAgentCommand.PermissionMode.init(rawValue:))
            ?? globalMode(defaults: defaults)
    }
}
