//
//  AttentionItem.swift
//  ArgosCore
//
//  Un elemento de la bandeja de atención: algo, en cualquier servidor, que espera al
//  usuario. Sabe qué es (por urgencia), a dónde lleva y si pide una respuesta (los que
//  la piden cuentan en la insignia del Dock; los informativos, no).
//

import Foundation

/// Qué espera al usuario, de más a menos urgente.
enum AttentionKind: Int, CaseIterable, Comparable, Sendable {
    /// Claude espera respuesta o permiso en una ventana de tmux.
    case claudeWaiting
    /// Una conversación del panel Agente tiene un permiso pendiente.
    case agentPermission
    /// Falló el CI de un push vigilado.
    case ciFailed
    /// Claude pide abrir un puerto en este dispositivo.
    case portRequest
    /// Un envío («Enviar al Mac / al servidor») falló.
    case syncFailed
    /// Un envío terminó.
    case syncFinished
    /// Claude terminó y aún no se ha mirado.
    case claudeDone

    static func < (lhs: AttentionKind, rhs: AttentionKind) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Pide una respuesta del usuario (cuenta en la insignia del Dock).
    var needsResponse: Bool {
        switch self {
        case .claudeWaiting, .agentPermission, .portRequest: return true
        case .ciFailed, .syncFailed, .syncFinished, .claudeDone: return false
        }
    }

    /// Símbolo (siempre acompañado de texto: nada depende solo del color).
    var systemImage: String {
        switch self {
        case .claudeWaiting: return "hand.raised.fill"
        case .agentPermission: return "lock.shield"
        case .ciFailed: return "xmark.octagon"
        case .portRequest: return "network"
        case .syncFailed: return "exclamationmark.arrow.triangle.2.circlepath"
        case .syncFinished: return "checkmark.circle"
        case .claudeDone: return "checkmark.seal"
        }
    }

    /// Nombre del tipo para VoiceOver y para el resumen.
    var label: String {
        switch self {
        case .claudeWaiting: return "Claude espera tu respuesta"
        case .agentPermission: return "Permiso pendiente del agente"
        case .ciFailed: return "Falló el CI"
        case .portRequest: return "Claude quiere abrir un puerto"
        case .syncFailed: return "Falló un envío"
        case .syncFinished: return "Envío terminado"
        case .claudeDone: return "Claude terminó"
        }
    }
}

/// A dónde lleva elegir el elemento.
enum AttentionDestination: Equatable, Hashable, Sendable {
    /// Terminal de la sesión (y su ventana de tmux, si se sabe).
    case terminal(SessionHandle, window: Int?)
    /// Pestaña del panel Agente.
    case agent(SessionHandle, tabID: UUID)
    /// Un modo concreto del proyecto (p. ej. «Cambios» para el CI).
    case project(SessionHandle, mode: DetailMode)
    /// El servidor (sin proyecto concreto).
    case server(Server.ID)
    /// La hoja del envío de un proyecto.
    case sync(serverID: Server.ID, projectID: UUID)
}

struct AttentionItem: Identifiable, Equatable, Hashable, Sendable {
    /// Estable mientras dure lo que representa (para recorrer la bandeja y descartar).
    let id: String
    let kind: AttentionKind
    let serverID: Server.ID
    /// Lo principal: el proyecto o la sesión («web», «api · ventana 2»).
    let title: String
    /// Lo secundario: qué pasa («Necesita permiso», «Puerto 3000 · La web»…).
    let detail: String
    let destination: AttentionDestination

    var needsResponse: Bool { kind.needsResponse }

    /// Frase completa para VoiceOver.
    func accessibilityLabel(serverName: String) -> String {
        "\(kind.label): \(title), \(detail), en \(serverName)"
    }
}
