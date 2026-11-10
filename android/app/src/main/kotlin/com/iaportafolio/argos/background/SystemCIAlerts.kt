package com.iaportafolio.argos.background

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.net.toUri
import com.iaportafolio.argos.MainActivity
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.github.CIResult
import com.iaportafolio.argos.data.ArgosLog

/**
 * «CI de app: pasó/falló» como notificación del sistema (canal propio, para poder silenciarlo
 * aparte de los agentes). Al tocarla se abre la ejecución en GitHub (o Argos si no hay URL).
 */
class SystemCIAlerts(context: Context) : CIAlertSink {
    private val appContext = context.applicationContext
    private val manager = NotificationManagerCompat.from(appContext)

    // Si el permiso falta, `areNotificationsEnabled` es falso; la captura cubre que lo retiren a medias.
    @SuppressLint("MissingPermission")
    override fun post(serverId: String, serverName: String, result: CIResult) {
        if (!manager.areNotificationsEnabled()) return
        ArgosNotificationChannels.ensure(appContext)
        val publicVersion = NotificationCompat.Builder(appContext, ArgosNotificationChannels.CI)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(appContext.getString(R.string.notification_ci_public))
            .build()
        val notification = NotificationCompat.Builder(appContext, ArgosNotificationChannels.CI)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(result.title)
            .setContentText(result.body)
            .setSubText(serverName)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setAutoCancel(true)
            .setContentIntent(open(result))
            .build()
        try {
            manager.notify("ci:$serverId:${result.watch.root}", NOTIFICATION_ID, notification)
        } catch (error: SecurityException) {
            ArgosLog.warn(ArgosLog.TAG_SSH, "Sin permiso para el aviso de CI (${error::class.java.simpleName})")
        }
    }

    private fun open(result: CIResult): PendingIntent {
        val intent = result.url?.let { Intent(Intent.ACTION_VIEW, it.toUri()) }
            ?: Intent(appContext, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(appContext, result.watch.root.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE)
    }

    private companion object {
        const val NOTIFICATION_ID = 2
    }
}
