package com.iaportafolio.argos.ui.agents

import com.iaportafolio.argos.core.agent.AgentStatus
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.ui.common.UiText

sealed interface AgentChatLoad {
    data object Loading : AgentChatLoad

    data class Failed(val message: UiText) : AgentChatLoad

    /** El agente ya no está en el servidor (borrado desde otro dispositivo). */
    data object Missing : AgentChatLoad

    data object Ready : AgentChatLoad
}

/** Estado del enganche al log (el agente sigue en el servidor pase lo que pase aquí). */
sealed interface AgentConnection {
    data object Connecting : AgentConnection

    data object Connected : AgentConnection

    /** Caído; [retryInSeconds] no nulo = esperando al reintento número [attempt]. */
    data class Retrying(val attempt: Int, val retryInSeconds: Int?) : AgentConnection

    /** Se agotaron los reintentos: hace falta pulsar «Reconectar». */
    data class Lost(val message: UiText) : AgentConnection
}

/** Lo que el usuario debe saber del agente, de un vistazo. */
enum class AgentChatStatus { CONNECTING, WORKING, IDLE, AWAITING_PERMISSION, TERMINATED, ERROR }

/** Mensajes de una sola vez hacia la pantalla. */
sealed interface AgentChatEvent {
    /** El mensaje llegó al agente: se vacía la caja de texto (si falla, se conserva). */
    data object MessageSent : AgentChatEvent

    /** La conversación se borró: se cierra la pantalla. */
    data object Closed : AgentChatEvent
}

data class AgentChatUiState(
    val title: String = "",
    val workingDirectory: String = "",
    /** El de `meta.json`, conocido al abrir: dice si este agente corre sin preguntar. */
    val permissionMode: ClaudeAgentCommand.PermissionMode? = null,
    val load: AgentChatLoad = AgentChatLoad.Loading,
    val rows: List<AgentTranscriptRow> = emptyList(),
    val conversationStatus: AgentStatus = AgentStatus.Idle,
    val isAlive: Boolean = true,
    val isReplaying: Boolean = false,
    val connection: AgentConnection = AgentConnection.Connecting,
    val permission: AgentPermissionCard? = null,
    val isSending: Boolean = false,
    val isResponding: Boolean = false,
    val isResuming: Boolean = false,
    val isStopping: Boolean = false,
    val isDeleting: Boolean = false,
    val confirmDelete: Boolean = false,
    /** Fallo de la última acción; se ve en la pantalla hasta que otra acción sale bien. */
    val error: UiText? = null,
) {
    val status: AgentChatStatus
        get() = when {
            load != AgentChatLoad.Ready -> AgentChatStatus.CONNECTING
            !isAlive -> AgentChatStatus.TERMINATED
            isReplaying -> AgentChatStatus.CONNECTING
            visiblePermission != null -> AgentChatStatus.AWAITING_PERMISSION
            error != null -> AgentChatStatus.ERROR
            else -> when (conversationStatus) {
                AgentStatus.Connecting -> AgentChatStatus.CONNECTING
                AgentStatus.Idle -> AgentChatStatus.IDLE
                AgentStatus.Working -> AgentChatStatus.WORKING
                AgentStatus.Finished -> AgentChatStatus.TERMINATED
                is AgentStatus.Failed -> AgentChatStatus.ERROR
            }
        }

    /** Un agente muerto no puede esperar respuesta: su petición ya no se muestra. */
    val visiblePermission: AgentPermissionCard? get() = permission?.takeIf { isAlive && !isReplaying }

    /** Solo se decide con el enganche vivo: lo que se ve es lo que el agente pide ahora. */
    val canDecidePermission: Boolean get() = connection == AgentConnection.Connected && !isResponding

    val canSend: Boolean get() = load == AgentChatLoad.Ready && isAlive && !isSending
}
