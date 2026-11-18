package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.git.ClaudeDoneMessage
import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.core.status.ClaudeTransition
import com.iaportafolio.argos.data.ServerRepository

/** «Claude terminó / espera tu respuesta» en una ventana tmux, listo para publicar. */
data class ClaudeAlert(
    val serverId: String,
    val serverName: String,
    val session: String,
    val window: Int,
    val activity: ClaudeActivity,
) {
    /** Textos de `AgentNotifier.postClaude` de iOS. */
    val title: String get() = activity.label
    val subtitle: String get() = "$session · ventana $window · $serverName"
    val body: String
        get() = if (activity == ClaudeActivity.WAITING) WAITING_BODY else ClaudeDoneMessage.body(null)

    companion object {
        const val WAITING_BODY = "Necesita permiso o una respuesta para continuar."

        fun from(transition: ClaudeTransition, serverId: String, serverName: String) =
            ClaudeAlert(serverId, serverName, transition.session, transition.window, transition.activity)
    }
}

/** Publica los avisos de Claude en el sistema. La implementación real es [SystemClaudeAlerts]. */
interface ClaudeAlertSink {
    fun canNotify(): Boolean

    /** Un aviso por ventana: uno nuevo sustituye al anterior de la misma ventana. */
    fun post(alert: ClaudeAlert)

    /** Retira el aviso de esa ventana (el usuario la está mirando). */
    fun cancel(serverId: String, session: String, window: Int)
}

/** La ventana que hay en pantalla: de ella no se avisa (ya se ve). */
data class ViewedWindow(val serverId: String, val session: String, val window: Int?) {
    /** `window == null` = aún no se sabe cuál es la activa: se calla toda la sesión. */
    fun covers(serverId: String, transition: ClaudeTransition): Boolean =
        this.serverId == serverId && session == transition.session && (window == null || window == transition.window)
}

/** El destino de un aviso de Claude, ya validado. */
data class ClaudeTarget(val serverId: String, val session: String, val window: Int)

/**
 * Datos del `Intent` de un aviso de Claude. `MainActivity` está exportada: cualquier app puede
 * lanzarla con estos extras, así que no se confía en ellos hasta pasar por [parse].
 */
object ClaudeLink {
    const val ACTION_OPEN_WINDOW = "com.iaportafolio.argos.action.OPEN_CLAUDE_WINDOW"
    const val EXTRA_SERVER_ID = "com.iaportafolio.argos.extra.SERVER_ID"
    const val EXTRA_SESSION = "com.iaportafolio.argos.extra.SESSION"
    const val EXTRA_WINDOW = "com.iaportafolio.argos.extra.WINDOW"

    /** Un nombre de sesión de tmux razonable (los de Argos no pasan de esto). */
    private const val MAX_SESSION_LENGTH = 256
    private const val MAX_WINDOW_INDEX = 10_000

    /** `null` (se ignora) salvo que sea la acción del aviso, el servidor exista y los datos sean sensatos. */
    fun parse(action: String?, serverId: String?, session: String?, window: Int, servers: ServerRepository): ClaudeTarget? {
        if (action != ACTION_OPEN_WINDOW || serverId == null || session == null) return null
        if (session.isEmpty() || session.length > MAX_SESSION_LENGTH || session.any { it.isISOControl() }) return null
        if (window !in 0..MAX_WINDOW_INDEX || servers.server(serverId) == null) return null
        return ClaudeTarget(serverId, session, window)
    }
}
