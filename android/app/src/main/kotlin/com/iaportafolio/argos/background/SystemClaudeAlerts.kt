package com.iaportafolio.argos.background

import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.iaportafolio.argos.MainActivity
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog

/**
 * [ClaudeAlertSink] con notificaciones del sistema, en el canal de avisos de agentes (el mismo
 * interruptor de Ajustes). En la pantalla de bloqueo solo se ve la versión pública: el nombre de la
 * sesión puede decir de qué va el proyecto.
 */
class SystemClaudeAlerts(context: Context) : ClaudeAlertSink {
    private val appContext = context.applicationContext
    private val manager = NotificationManagerCompat.from(appContext)

    override fun canNotify(): Boolean = agentNotificationsAllowed(appContext)

    // Si falta el permiso, `areNotificationsEnabled` ya es falso y aquí no se llega.
    @SuppressLint("MissingPermission")
    override fun post(alert: ClaudeAlert) {
        ArgosNotificationChannels.ensure(appContext)
        try {
            manager.notify(tag(alert.serverId, alert.session, alert.window), NOTIFICATION_ID, build(alert))
        } catch (error: SecurityException) {
            ArgosLog.warn(ArgosLog.TAG_AGENT, "Sin permiso para publicar el aviso de Claude (${error::class.java.simpleName})")
        }
    }

    override fun cancel(serverId: String, session: String, window: Int) =
        manager.cancel(tag(serverId, session, window), NOTIFICATION_ID)

    private fun build(alert: ClaudeAlert): Notification {
        val publicVersion = NotificationCompat.Builder(appContext, ArgosNotificationChannels.AGENTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(appContext.getString(R.string.notification_claude_public))
            .build()
        return NotificationCompat.Builder(appContext, ArgosNotificationChannels.AGENTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(alert.title)
            .setContentText(alert.body)
            .setSubText(alert.subtitle)
            .setStyle(NotificationCompat.BigTextStyle().bigText(alert.body))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setGroup("claude:${alert.serverId}:${alert.session}")
            .setAutoCancel(true)
            .setContentIntent(openWindow(alert))
            .build()
    }

    private fun openWindow(alert: ClaudeAlert): PendingIntent {
        val tag = tag(alert.serverId, alert.session, alert.window)
        val intent = Intent(appContext, MainActivity::class.java)
            .setAction(ClaudeLink.ACTION_OPEN_WINDOW)
            // Distingue los `PendingIntent` de cada ventana (si no, se pisarían los extras).
            .setIdentifier(tag)
            .putExtra(ClaudeLink.EXTRA_SERVER_ID, alert.serverId)
            .putExtra(ClaudeLink.EXTRA_SESSION, alert.session)
            .putExtra(ClaudeLink.EXTRA_WINDOW, alert.window)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(appContext, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun tag(serverId: String, session: String, window: Int) = "claude:$serverId:$session:$window"

    private companion object {
        /** Fijo: con la etiqueta por ventana, cada aviso sustituye al anterior de la misma ventana. */
        const val NOTIFICATION_ID = 2
    }
}
