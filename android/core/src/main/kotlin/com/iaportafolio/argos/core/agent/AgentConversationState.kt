package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.JsonElement

/*
 * Estado de la conversación del agente y su reducer PURO (port de
 * `ArgosCore/Agent/AgentConversationState.swift`). Los ids de los items son enteros
 * incrementales (no UUID): dos reducciones idénticas son iguales.
 */

/** Estado de la conexión/turno del agente, para el feedback de la UI. */
sealed interface AgentStatus {
    /** Lanzando el proceso remoto, antes del `init`. */
    data object Connecting : AgentStatus

    /** Listo para recibir un prompt del usuario. */
    data object Idle : AgentStatus

    /** Turno en curso (el modelo está trabajando). */
    data object Working : AgentStatus

    /** El proceso remoto terminó (EOF) de forma normal. */
    data object Finished : AgentStatus

    /** Fallo de transporte o del proceso. */
    data class Failed(val message: String) : AgentStatus
}

/** Un elemento renderizable del transcript, con `id` entero estable y determinista. */
data class AgentTranscriptItem(val id: Int, val kind: Kind) {

    sealed interface Kind {
        data class UserText(val text: String) : Kind
        data class AssistantText(val text: String) : Kind
        data class Thinking(val text: String) : Kind
        data class ToolUse(val name: String, val input: JsonElement) : Kind
        data class ToolResult(val text: String, val isError: Boolean) : Kind
        data class Result(val result: AgentResult) : Kind
        data class Error(val message: String) : Kind
    }
}

/**
 * Estado completo de una conversación de agente (inmutable).
 *
 * Arranca en [AgentStatus.Idle]: `claude` en modo stream-json NO emite `init` hasta
 * recibir input, así que no hay que esperar a «conectar».
 */
data class AgentConversationState(
    val items: List<AgentTranscriptItem> = emptyList(),
    val status: AgentStatus = AgentStatus.Idle,
    val pendingPermission: AgentPermissionRequest? = null,
    val sessionID: String? = null,
    /** Id del próximo item (contador determinista). */
    val nextItemId: Int = 0,
) {
    /** Devuelve el estado con [kind] añadido al transcript con id estable. */
    fun appending(kind: AgentTranscriptItem.Kind): AgentConversationState =
        copy(items = items + AgentTranscriptItem(nextItemId, kind), nextItemId = nextItemId + 1)
}

/** Reductor puro: aplica un evento del CLI (o una acción del usuario) al estado. */
object AgentReducer {

    /**
     * Aplica un evento decodificado del stream-json.
     *
     * [echoesUserMessages]: el log trae los prompts del usuario (`--replay-user-messages`,
     * agente persistente). Entonces los textos de eventos `user` son burbujas del usuario
     * y no se añaden localmente al enviar.
     */
    fun apply(
        event: AgentStreamEvent,
        state: AgentConversationState,
        echoesUserMessages: Boolean = false,
    ): AgentConversationState = when (event) {
        is AgentStreamEvent.Initialized -> state.copy(
            sessionID = event.info.sessionID,
            status = if (state.status == AgentStatus.Connecting) AgentStatus.Idle else state.status,
        )

        is AgentStreamEvent.Assistant -> event.blocks.fold(state, ::appendBlock)

        is AgentStreamEvent.User -> event.blocks.fold(state) { current, block ->
            when {
                block is AgentContentBlock.ToolResult ->
                    current.appending(AgentTranscriptItem.Kind.ToolResult(block.text, block.isError))
                block is AgentContentBlock.Text && echoesUserMessages && block.text.isNotEmpty() ->
                    userSent(block.text, current)
                else -> current
            }
        }

        is AgentStreamEvent.PermissionRequest -> state.copy(pendingPermission = event.request)

        is AgentStreamEvent.PermissionCancel ->
            if (state.pendingPermission?.id == event.requestID) state.copy(pendingPermission = null) else state

        is AgentStreamEvent.Result ->
            state.appending(AgentTranscriptItem.Kind.Result(event.result)).copy(status = AgentStatus.Idle)

        is AgentStreamEvent.RateLimit, is AgentStreamEvent.Ignored -> state
    }

    /** Registra el envío de un prompt del usuario (cambia a «trabajando»). */
    fun userSent(text: String, state: AgentConversationState): AgentConversationState =
        state.appending(AgentTranscriptItem.Kind.UserText(text)).copy(status = AgentStatus.Working)

    /** Marca el fin de la conexión (EOF si [error] es `null`, o error de transporte). */
    fun finished(error: String?, state: AgentConversationState): AgentConversationState {
        val cleared = state.copy(pendingPermission = null)
        return if (error != null) {
            cleared.appending(AgentTranscriptItem.Kind.Error(error)).copy(status = AgentStatus.Failed(error))
        } else {
            cleared.copy(status = AgentStatus.Finished)
        }
    }

    private fun appendBlock(state: AgentConversationState, block: AgentContentBlock): AgentConversationState =
        when (block) {
            is AgentContentBlock.Text ->
                if (block.text.isNotEmpty()) state.appending(AgentTranscriptItem.Kind.AssistantText(block.text)) else state
            is AgentContentBlock.Thinking ->
                if (block.text.isNotEmpty()) state.appending(AgentTranscriptItem.Kind.Thinking(block.text)) else state
            is AgentContentBlock.ToolUse -> state.appending(AgentTranscriptItem.Kind.ToolUse(block.name, block.input))
            is AgentContentBlock.ToolResult ->
                state.appending(AgentTranscriptItem.Kind.ToolResult(block.text, block.isError))
        }
}
