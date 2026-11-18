//
//  AgentLaunchPreferences.swift
//  Argos
//
//  Dónde vive una conversación nueva del panel Agente del Mac, recordado por proyecto
//  (en este dispositivo; nunca en `projects.json`):
//   - «Solo en esta sesión» (predeterminado): `claude` vive con la conexión de Argos y se
//     detiene al cerrar la pestaña o salir. Es lo de siempre y no deja procesos de
//     ~0,5 GB en el servidor cuando el usuario no los pidió (el servidor ya se quedó sin
//     memoria una vez por acumularlos).
//   - «Mantener en el servidor»: agente persistente, que sigue aunque se cierre Argos o se
//     corte la red y que se puede continuar desde el iPhone/iPad o Android.
//

import Foundation

enum AgentConversationPlacement: String, CaseIterable, Sendable {
    case session
    case server

    var title: String {
        switch self {
        case .session: return "Solo en esta sesión"
        case .server: return "Mantener en el servidor"
        }
    }

    var detail: String {
        switch self {
        case .session: return "Se detiene al cerrar la pestaña o salir de Argos."
        case .server: return "Sigue aunque cierres Argos o se corte la red; puedes continuarla desde el iPhone."
        }
    }

    var systemImage: String {
        switch self {
        case .session: return "laptopcomputer"
        case .server: return "server.rack"
        }
    }
}

enum AgentLaunchPreferences {

    static let fallback = AgentConversationPlacement.session
    /// Sin puntos: `UserDefaults` observa las claves como rutas KVO.
    static let keyPrefix = "agentPlacement"

    static func key(serverID: UUID, workingDirectory: String) -> String {
        let path = Data(AgentFolderMatch.normalized(workingDirectory).utf8).base64EncodedString()
        return "\(keyPrefix):\(serverID.uuidString):\(path)"
    }

    /// Lo guardado; un valor que no se reconoce vuelve al predeterminado.
    static func stored(_ raw: String?) -> AgentConversationPlacement {
        raw.flatMap(AgentConversationPlacement.init(rawValue:)) ?? fallback
    }

    static func placement(serverID: UUID, workingDirectory: String, defaults: UserDefaults = .standard) -> AgentConversationPlacement {
        stored(defaults.string(forKey: key(serverID: serverID, workingDirectory: workingDirectory)))
    }

    static func setPlacement(
        _ placement: AgentConversationPlacement,
        serverID: UUID,
        workingDirectory: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(placement.rawValue, forKey: key(serverID: serverID, workingDirectory: workingDirectory))
    }
}
