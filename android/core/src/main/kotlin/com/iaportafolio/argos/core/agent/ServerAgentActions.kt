package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.SSHServicing

/**
 * Acciones de «Agentes en este servidor» sobre el inventario ([ServerAgentInventory]) (port de
 * `ArgosCore/Agent/ServerAgentActions.swift`): parar agentes (persistentes por su carpeta, del
 * panel por PID verificado) e hibernar los inactivos. Devuelven los ids que no se pudieron tratar
 * (p. ej. un proceso atascado).
 */
object ServerAgentActions {

    /** Para [agents]. Los persistentes se pueden reanudar después. */
    suspend fun stop(agents: List<ServerAgentProcess>, service: SSHServicing): List<String> {
        val persistent = agents.filter { it.kind is ServerAgentProcess.Kind.Persistent }.map { it.sessionID }
        val panel = agents.mapNotNull { agent ->
            (agent.kind as? ServerAgentProcess.Kind.Panel)?.let { it.pid to agent.sessionID }
        }
        val failed = if (persistent.isEmpty()) {
            emptyList()
        } else {
            ServerAgentInventory.failures(service.runAgentScript(ServerAgentInventory.stopPersistent(persistent)))
        }
        if (panel.isNotEmpty()) service.runAgentScript(ServerAgentInventory.stopPanel(panel))
        return failed
    }

    /** Hiberna [agents] si en el servidor siguen quietos desde hace [minIdleSeconds]. */
    suspend fun hibernate(agents: List<ServerAgentProcess>, minIdleSeconds: Int, service: SSHServicing): List<String> {
        if (agents.isEmpty()) return emptyList()
        val output = service.runAgentScript(ServerAgentInventory.hibernate(agents.map { it.sessionID }, minIdleSeconds))
        return ServerAgentInventory.failures(output)
    }

    /** Nombres (su título si se conoce) de los que no se pudieron tratar, o `null` si no hay. */
    fun failedNames(failed: List<String>, inventory: ServerAgentInventory?): String? {
        if (failed.isEmpty()) return null
        return failed.joinToString(", ") { id -> inventory?.agents?.firstOrNull { it.sessionID == id }?.title ?: id }
    }
}
