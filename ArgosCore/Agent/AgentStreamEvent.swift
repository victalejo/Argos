//
//  AgentStreamEvent.swift
//  Argos
//
//  Modelos puros (sin red/UI) del protocolo `stream-json` del CLI `claude` headless.
//  Representan lo que llega por stdout ya decodificado a un enum manejable. La forma
//  exacta del protocolo está documentada en la memoria del proyecto
//  (argos-claude-agent-protocol) y verificada contra `claude` v2.1.183.
//

import Foundation

/// Un bloque de contenido dentro de un mensaje del asistente o de un tool result.
enum AgentContentBlock: Sendable, Equatable {
    /// Texto visible del asistente.
    case text(String)
    /// Razonamiento (extended thinking). Puede venir vacío.
    case thinking(String)
    /// Invocación de una herramienta por el modelo.
    case toolUse(id: String, name: String, input: JSONValue)
    /// Resultado de una herramienta (llega en mensajes `user`).
    case toolResult(toolUseID: String, text: String, isError: Bool)
}

/// Solicitud de permiso para usar una herramienta (subtype `can_use_tool`).
///
/// `id` es el `request_id` que debe devolverse en el `control_response`.
struct AgentPermissionRequest: Sendable, Equatable, Identifiable {
    let id: String
    let toolName: String
    let displayName: String?
    let input: JSONValue
    let toolUseID: String?
}

/// Resultado final de un turno (`type: "result"`).
struct AgentResult: Sendable, Equatable {
    let subtype: String
    let isError: Bool
    let text: String?
    let totalCostUSD: Double?
}

/// Información mínima del evento de inicialización (`system/init`).
struct AgentInit: Sendable, Equatable {
    let sessionID: String
    let model: String?
}

/// Un evento de alto nivel decodificado de una línea NDJSON del CLI.
enum AgentStreamEvent: Sendable, Equatable {
    /// Inicio de la sesión del agente.
    case initialized(AgentInit)
    /// Mensaje del asistente con sus bloques de contenido.
    case assistant([AgentContentBlock])
    /// Mensaje de usuario reflejado (normalmente tool results).
    case user([AgentContentBlock])
    /// El agente pide permiso para usar una herramienta.
    case permissionRequest(AgentPermissionRequest)
    /// Se canceló una solicitud de permiso pendiente.
    case permissionCancel(requestID: String)
    /// Turno finalizado.
    case result(AgentResult)
    /// Evento de límite de uso (informativo).
    case rateLimit
    /// Evento reconocido pero no accionable (hooks, system no-init, control_response…).
    case ignored(type: String, subtype: String?)
}
