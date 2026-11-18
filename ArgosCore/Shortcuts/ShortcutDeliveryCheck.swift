//
//  ShortcutDeliveryCheck.swift
//  ArgosCore
//
//  Comprobación JUSTO ANTES de entregar el encargo del atajo (lógica pura, con tests).
//  Entre la confirmación y el envío pasan segundos y el `meta.json` del agente vive en el
//  servidor: otro dispositivo, o cualquiera con acceso al servidor, puede cambiar su modo
//  a «sin preguntar» o el agente puede desaparecer. Se vuelve a leer y solo se entrega
//  (o se reanuda) si sigue siendo lo que el usuario vio: el mismo agente, en la misma
//  carpeta y con un modo que o bien pregunta, o bien es EXACTAMENTE el aprobado.
//

import Foundation

enum ShortcutDeliveryVerdict: Equatable, Sendable {
    case deliver
    /// El agente elegido ya no existe en el servidor.
    case agentGone
    /// El agente ahora trabaja en otra carpeta (no es el del proyecto).
    case agentMoved
    /// Su modo cambió a uno que actúa sin preguntar y no es el aprobado.
    case modeChanged
}

extension ShortcutAgentPlan {
    /// Modo tal como se leyó (texto de `meta.json`, o el del agente que se va a crear):
    /// es lo que el usuario aprobó, comparado letra a letra en la entrega.
    var approvedRawMode: String? {
        switch self {
        case .reuse(let info), .resume(let info): return info.meta.permissionMode
        case .create(let mode): return mode.rawValue
        }
    }
}

extension ShortcutAgentPlanner {

    /// ¿Se puede entregar a un agente cuyo `meta.json` dice ahora `current`?
    /// Un modo que pregunta siempre vale; uno que actúa solo (o desconocido) solo si es
    /// exactamente el aprobado: si al preparar no hacía falta confirmar, ese modo no se
    /// aprobó y no se usa.
    static func mayDeliver(approvedRawMode: String?, currentRawMode: String?) -> Bool {
        let current = declaredMode(raw: currentRawMode)
        guard requiresConfirmation(mode: current, allowsUnconfirmed: false) else { return true }
        return approvedRawMode == currentRawMode
    }

    /// Veredicto con lo que se acaba de releer del servidor (`nil`: el agente ya no está).
    static func deliveryVerdict(
        approvedRawMode: String?,
        workingDirectory: String,
        current: PersistentAgentMeta?
    ) -> ShortcutDeliveryVerdict {
        guard let current else { return .agentGone }
        guard normalized(current.workingDirectory) == normalized(workingDirectory) else { return .agentMoved }
        guard mayDeliver(approvedRawMode: approvedRawMode, currentRawMode: current.permissionMode) else {
            return .modeChanged
        }
        return .deliver
    }
}
