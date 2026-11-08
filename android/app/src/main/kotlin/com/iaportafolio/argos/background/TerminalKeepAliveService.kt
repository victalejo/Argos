package com.iaportafolio.argos.background

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.iaportafolio.argos.AppContainer
import com.iaportafolio.argos.ArgosApplication
import com.iaportafolio.argos.MainActivity
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Mantiene vivo el proceso mientras haya terminales adjuntos: la conexión y el bombeo al emulador
 * viven en los `TerminalViewModel`, aquí no hay nada de SSH. Mientras dura, revisa también los
 * avisos de agentes más a menudo que WorkManager.
 *
 * Sin WifiLock ni WakeLock, a propósito: si el sistema duerme y corta la red, el reintento con
 * backoff del terminal lo resuelve al volver. La notificación nunca muestra contenido de la sesión.
 */
class TerminalKeepAliveService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val container: AppContainer get() = (application as ArgosApplication).container
    private var lastStartId = 0
    private var stoppedOnPurpose = false
    private var stopJob: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ArgosNotificationChannels.ensure(this)
        scope.launch {
            container.activeTerminals.count.collect { count ->
                if (count > 0) enterForeground(count)
                stopSoonIfIdle()
            }
        }
        scope.launch { runEvery(AGENT_CHECK_INTERVAL_MILLIS) { container.agentNotifier.check() } }
    }

    /**
     * Siempre pasa a primer plano antes que nada: cada `startForegroundService` lo exige, aunque
     * entretanto se haya cerrado el último terminal.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        if (enterForeground(container.activeTerminals.count.value) && intent?.action == ACTION_DISCONNECT_ALL) {
            container.activeTerminals.disconnectAll()
        }
        stopSoonIfIdle()
        // Si el proceso muere, mueren también los terminales: no hay nada que recuperar.
        return START_NOT_STICKY
    }

    /**
     * Sin terminales, se para tras un margen (así no parpadea la notificación al pasar de un
     * terminal a otro). Con [lastStartId] el sistema no lo para si hay un arranque aún sin entregar
     * (se rompería la promesa de `startForeground`); ese `onStartCommand` volverá a pasar por aquí.
     */
    private fun stopSoonIfIdle() {
        stopJob?.cancel()
        if (container.activeTerminals.count.value > 0) return
        stopJob = scope.launch {
            delay(STOP_GRACE_MILLIS)
            if (stopSelfResult(lastStartId)) stoppedOnPurpose = true
        }
    }

    private fun enterForeground(count: Int): Boolean = try {
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification(count),
            // `specialUse` no existe antes de Android 14, donde tampoco hace falta indicar tipo.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0,
        )
        true
    } catch (error: IllegalStateException) {
        // Incluye ForegroundServiceStartNotAllowedException (Android 12+).
        onForegroundDenied(error)
        false
    } catch (error: SecurityException) {
        onForegroundDenied(error)
        false
    }

    private fun onForegroundDenied(error: Exception) {
        ArgosLog.warn(ArgosLog.TAG_TERMINAL, "El servicio no pudo pasar a primer plano (${error::class.java.simpleName})")
        stoppedOnPurpose = true
        container.activeTerminals.serviceLost()
        stopSelf()
    }

    /** La app se cerró desde recientes: detach y fuera. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        container.activeTerminals.disconnectAll()
        stoppedOnPurpose = true
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        scope.cancel()
        if (!stoppedOnPurpose) container.activeTerminals.serviceLost()
        super.onDestroy()
    }

    private fun notification(count: Int): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val disconnect = PendingIntent.getService(
            this,
            0,
            Intent(this, TerminalKeepAliveService::class.java).setAction(ACTION_DISCONNECT_ALL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, ArgosNotificationChannels.KEEP_ALIVE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(resources.getQuantityString(R.plurals.keep_alive_notification, count, count))
            .setContentIntent(open)
            .addAction(R.drawable.ic_stop, getString(R.string.keep_alive_disconnect_all), disconnect)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        private const val ACTION_DISCONNECT_ALL = "com.iaportafolio.argos.action.DISCONNECT_ALL_TERMINALS"
        private const val NOTIFICATION_ID = 100
        private const val STOP_GRACE_MILLIS = 1_000L
        private const val AGENT_CHECK_INTERVAL_MILLIS = 60_000L

        /** Host real del registro. Falla (`false`) si el sistema no deja arrancarlo ahora. */
        fun host(context: Context) = TerminalKeepAliveHost {
            val appContext = context.applicationContext
            try {
                ContextCompat.startForegroundService(appContext, Intent(appContext, TerminalKeepAliveService::class.java))
                true
            } catch (error: IllegalStateException) {
                // Incluye ForegroundServiceStartNotAllowedException (Android 12+).
                ArgosLog.warn(ArgosLog.TAG_TERMINAL, "No se pudo arrancar el servicio (${error::class.java.simpleName})")
                false
            } catch (error: SecurityException) {
                ArgosLog.warn(ArgosLog.TAG_TERMINAL, "No se pudo arrancar el servicio (${error::class.java.simpleName})")
                false
            }
        }
    }
}
