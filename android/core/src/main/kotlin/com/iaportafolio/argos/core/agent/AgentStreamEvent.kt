package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.JsonElement

/*
 * Modelos puros del protocolo `stream-json` del CLI `claude` headless (port de
 * `ArgosCore/Agent/AgentStreamEvent.swift`): lo que llega por stdout ya decodificado.
 */

/** Un bloque de contenido dentro de un mensaje del asistente o de un tool result. */
sealed interface AgentContentBlock {
    /** Texto visible del asistente. */
    data class Text(val text: String) : AgentContentBlock

    /** Razonamiento (extended thinking). Puede venir vacío. */
    data class Thinking(val text: String) : AgentContentBlock

    /** Invocación de una herramienta por el modelo. */
    data class ToolUse(val id: String, val name: String, val input: JsonElement) : AgentContentBlock

    /** Resultado de una herramienta (llega en mensajes `user`). */
    data class ToolResult(val toolUseID: String, val text: String, val isError: Boolean) : AgentContentBlock
}

/**
 * Solicitud de permiso para usar una herramienta (subtype `can_use_tool`).
 *
 * [id] es el `request_id` que debe devolverse en el `control_response`.
 */
data class AgentPermissionRequest(
    val id: String,
    val toolName: String,
    val displayName: String?,
    val input: JsonElement,
    val toolUseID: String?,
)

/** Resultado final de un turno (`type: "result"`). */
data class AgentResult(
    val subtype: String,
    val isError: Boolean,
    val text: String?,
    val totalCostUSD: Double?,
)

/** Información mínima del evento de inicialización (`system/init`). */
data class AgentInit(val sessionID: String, val model: String?)

/** Un evento de alto nivel decodificado de una línea NDJSON del CLI. */
sealed interface AgentStreamEvent {
    /** Inicio de la sesión del agente. */
    data class Initialized(val info: AgentInit) : AgentStreamEvent

    /** Mensaje del asistente con sus bloques de contenido. */
    data class Assistant(val blocks: List<AgentContentBlock>) : AgentStreamEvent

    /** Mensaje de usuario reflejado (normalmente tool results). */
    data class User(val blocks: List<AgentContentBlock>) : AgentStreamEvent

    /** El agente pide permiso para usar una herramienta. */
    data class PermissionRequest(val request: AgentPermissionRequest) : AgentStreamEvent

    /** Se canceló (o se respondió) una solicitud de permiso pendiente. */
    data class PermissionCancel(val requestID: String) : AgentStreamEvent

    /** Turno finalizado. */
    data class Result(val result: AgentResult) : AgentStreamEvent

    /** Evento de límite de uso (informativo). */
    data object RateLimit : AgentStreamEvent

    /** Evento reconocido pero no accionable (hooks, system no-init, control_response…). */
    data class Ignored(val type: String, val subtype: String?) : AgentStreamEvent
}

/** Decisión del usuario ante una solicitud de permiso de herramienta. */
sealed interface AgentPermissionDecision {
    /** Permite la herramienta, con el input (posiblemente ajustado). */
    data class Allow(val updatedInput: JsonElement) : AgentPermissionDecision

    /** Deniega la herramienta con un mensaje para el modelo. */
    data class Deny(val message: String) : AgentPermissionDecision

    companion object {
        /** Mensaje con el que las apps de Apple deniegan desde el botón «Denegar». */
        const val USER_DENIED_MESSAGE = "El usuario denegó esta acción."
    }
}
