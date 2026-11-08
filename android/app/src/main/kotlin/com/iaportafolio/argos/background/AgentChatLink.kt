package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.data.ServerRepository

/** El chat que abre un aviso, ya validado. */
data class AgentChatTarget(val serverId: String, val agentId: String)

/**
 * Datos del `Intent` de un aviso. `MainActivity` está exportada, así que cualquier app puede
 * lanzarla con estos extras: no se confía en ellos hasta pasar por [parse].
 */
object AgentChatLink {
    const val ACTION_OPEN_CHAT = "com.iaportafolio.argos.action.OPEN_AGENT_CHAT"
    const val EXTRA_SERVER_ID = "com.iaportafolio.argos.extra.SERVER_ID"
    const val EXTRA_AGENT_ID = "com.iaportafolio.argos.extra.AGENT_ID"

    /** `null` (se ignora) salvo que sea la acción del aviso, el servidor exista y el id sea un UUID. */
    fun parse(action: String?, serverId: String?, agentId: String?, servers: ServerRepository): AgentChatTarget? {
        if (action != ACTION_OPEN_CHAT || serverId == null || agentId == null) return null
        if (!PersistentAgentScript.isValidID(agentId) || servers.server(serverId) == null) return null
        return AgentChatTarget(serverId, agentId)
    }
}
