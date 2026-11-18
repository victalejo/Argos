package com.iaportafolio.argos.background

import android.content.Intent
import com.iaportafolio.argos.core.NotificationRoute
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.data.ServerRepository

/**
 * El chat que abre un aviso, ya validado. [projectPath]: carpeta del agente; si es la de un
 * proyecto, se abre proyecto → Agentes → chat (como `NotificationRoute` de Swift).
 */
data class AgentChatTarget(val serverId: String, val agentId: String, val projectPath: String? = null)

/**
 * Datos del `Intent` de un aviso, con las MISMAS claves que `NotificationRoute.swift`
 * (`argos.serverID`, `argos.projectPath`, `argos.tab`, `argos.agentID`). `MainActivity` está
 * exportada, así que cualquier app puede lanzarla con estos extras: no se confía en ellos hasta
 * pasar por [parse].
 */
object AgentChatLink {
    const val ACTION_OPEN_CHAT = "com.iaportafolio.argos.action.OPEN_AGENT_CHAT"

    /** Claves de las versiones anteriores (avisos ya publicados antes de actualizar). */
    private const val LEGACY_SERVER_ID = "com.iaportafolio.argos.extra.SERVER_ID"
    private const val LEGACY_AGENT_ID = "com.iaportafolio.argos.extra.AGENT_ID"

    /** Escribe la ruta del aviso en [intent]. */
    fun putRoute(intent: Intent, route: NotificationRoute): Intent {
        for ((key, value) in route.extras) {
            when (value) {
                is String -> intent.putExtra(key, value)
                is Int -> intent.putExtra(key, value)
            }
        }
        return intent
    }

    /** Ruta de un aviso de agente (la pestaña de agentes va implícita). */
    fun route(serverId: String, agentId: String, projectPath: String?): NotificationRoute =
        NotificationRoute.of(serverID = serverId, projectPath = projectPath, agentID = agentId)

    /** `null` (se ignora) salvo que sea la acción del aviso, el servidor exista y el id sea un UUID. */
    fun parse(action: String?, extra: (String) -> Any?, servers: ServerRepository): AgentChatTarget? {
        if (action != ACTION_OPEN_CHAT) return null
        val route = NotificationRoute.fromExtras(extra)
            ?: legacy(extra)
            ?: return null
        val agentId = route.agentID ?: return null
        if (!PersistentAgentScript.isValidID(agentId) || servers.server(route.serverID) == null) return null
        return AgentChatTarget(route.serverID, agentId, route.projectPath)
    }

    private fun legacy(extra: (String) -> Any?): NotificationRoute? {
        val server = extra(LEGACY_SERVER_ID) as? String ?: return null
        val agent = extra(LEGACY_AGENT_ID) as? String ?: return null
        return NotificationRoute.of(serverID = server, agentID = agent)
    }
}
