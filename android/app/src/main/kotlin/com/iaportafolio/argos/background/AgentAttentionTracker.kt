package com.iaportafolio.argos.background

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Lo que las pantallas cuentan a los avisos de agentes. Abstracción para sus tests. */
interface AgentAttentionTracker {
    val notificationsEnabled: StateFlow<Boolean>

    fun setNotificationsEnabled(enabled: Boolean)

    /** Se creó o abrió un agente: el servidor pasa a revisarse en segundo plano. */
    fun agentOpened(serverId: String)

    /** El chat está a la vista: no se avisa de ese agente y se retira su aviso. */
    fun chatShown(serverId: String, agentId: String)

    /** El chat deja de verse: lo leído ([receivedBytes]) ya no se avisa. */
    fun chatHidden(serverId: String, agentId: String, receivedBytes: Long)

    /** Borrar un servidor lo deja de revisar y limpia su estado. */
    fun serverDeleted(serverId: String)

    /** Sin avisos: los ViewModels que no los necesitan (y sus tests). */
    object None : AgentAttentionTracker {
        override val notificationsEnabled: StateFlow<Boolean> = MutableStateFlow(false).asStateFlow()
        override fun setNotificationsEnabled(enabled: Boolean) = Unit
        override fun agentOpened(serverId: String) = Unit
        override fun chatShown(serverId: String, agentId: String) = Unit
        override fun chatHidden(serverId: String, agentId: String, receivedBytes: Long) = Unit
        override fun serverDeleted(serverId: String) = Unit
    }
}

/** Un aviso listo para publicar. El texto ya pasó por el `SecretRedactor`. */
data class AgentAlert(
    val serverId: String,
    val serverName: String,
    val agentId: String,
    val title: String,
    val body: String,
)

/** Publica los avisos en el sistema. La implementación real es [SystemAgentAlerts]. */
interface AgentAlertSink {
    /** `false` si el sistema tiene bloqueadas las notificaciones de la app o de su canal. */
    fun canNotify(): Boolean

    /** Sustituye el aviso anterior de ese agente: nunca se apilan. */
    fun post(alert: AgentAlert)

    fun cancel(serverId: String, agentId: String)
}

/** Programa la comprobación periódica. La implementación real es [WorkManagerAgentCheckScheduler]. */
interface AgentCheckScheduler {
    fun schedule()

    fun cancel()
}
