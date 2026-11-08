package com.iaportafolio.argos.background

import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.iaportafolio.argos.MainActivity
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog

/** Canales de notificación de Argos. Crearlos es idempotente. */
internal object ArgosNotificationChannels {
    const val AGENTS = "agent_attention"
    const val KEEP_ALIVE = "terminal_keep_alive"

    fun ensure(context: Context) {
        NotificationManagerCompat.from(context).createNotificationChannelsCompat(
            listOf(
                NotificationChannelCompat.Builder(AGENTS, NotificationManagerCompat.IMPORTANCE_DEFAULT)
                    .setName(context.getString(R.string.notification_channel_agents))
                    .setDescription(context.getString(R.string.notification_channel_agents_description))
                    .build(),
                NotificationChannelCompat.Builder(KEEP_ALIVE, NotificationManagerCompat.IMPORTANCE_LOW)
                    .setName(context.getString(R.string.notification_channel_keep_alive))
                    .setDescription(context.getString(R.string.notification_channel_keep_alive_description))
                    .setSound(null, null)
                    .setVibrationEnabled(false)
                    .setShowBadge(false)
                    .build(),
            ),
        )
    }
}

/** ¿Deja el sistema mostrar los avisos de agentes? Bloqueados en la app o en su canal, no. */
internal fun agentNotificationsAllowed(context: Context): Boolean {
    val manager = NotificationManagerCompat.from(context)
    if (!manager.areNotificationsEnabled()) return false
    val channel = manager.getNotificationChannelCompat(ArgosNotificationChannels.AGENTS) ?: return true
    return channel.importance != NotificationManagerCompat.IMPORTANCE_NONE
}

/**
 * [AgentAlertSink] con notificaciones del sistema. El título y el cuerpo vienen del servidor: en la
 * pantalla de bloqueo solo se ve la versión pública, sin contenido.
 */
class SystemAgentAlerts(context: Context) : AgentAlertSink {
    private val appContext = context.applicationContext
    private val manager = NotificationManagerCompat.from(appContext)

    override fun canNotify(): Boolean = agentNotificationsAllowed(appContext)

    // Si el permiso falta, `areNotificationsEnabled` ya es falso y aquí no se llega; la captura
    // cubre que lo retiren justo en medio.
    @SuppressLint("MissingPermission")
    override fun post(alert: AgentAlert) {
        ArgosNotificationChannels.ensure(appContext)
        try {
            manager.notify(tag(alert.serverId, alert.agentId), NOTIFICATION_ID, build(alert))
        } catch (error: SecurityException) {
            ArgosLog.warn(ArgosLog.TAG_AGENT, "Sin permiso para publicar el aviso (${error::class.java.simpleName})")
        }
    }

    override fun cancel(serverId: String, agentId: String) = manager.cancel(tag(serverId, agentId), NOTIFICATION_ID)

    private fun build(alert: AgentAlert): Notification {
        val publicVersion = NotificationCompat.Builder(appContext, ArgosNotificationChannels.AGENTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(appContext.getString(R.string.notification_agent_public))
            .build()
        return NotificationCompat.Builder(appContext, ArgosNotificationChannels.AGENTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(alert.title)
            .setContentText(alert.body)
            .setSubText(alert.serverName)
            .setStyle(NotificationCompat.BigTextStyle().bigText(alert.body))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setGroup(alert.agentId)
            .setAutoCancel(true)
            .setContentIntent(openChat(alert))
            .build()
    }

    private fun openChat(alert: AgentAlert): PendingIntent {
        val tag = tag(alert.serverId, alert.agentId)
        val intent = Intent(appContext, MainActivity::class.java)
            .setAction(AgentChatLink.ACTION_OPEN_CHAT)
            // Distingue los `PendingIntent` de cada agente, que si no se pisarían los extras.
            .setIdentifier(tag)
            .putExtra(AgentChatLink.EXTRA_SERVER_ID, alert.serverId)
            .putExtra(AgentChatLink.EXTRA_AGENT_ID, alert.agentId)
            // Reutiliza la Activity (y sus terminales) aunque tenga encima un selector de archivos.
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(appContext, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun tag(serverId: String, agentId: String) = "agent:$serverId:$agentId"

    private companion object {
        /** Fijo: con la etiqueta por agente, cada aviso sustituye al anterior del mismo agente. */
        const val NOTIFICATION_ID = 1
    }
}
