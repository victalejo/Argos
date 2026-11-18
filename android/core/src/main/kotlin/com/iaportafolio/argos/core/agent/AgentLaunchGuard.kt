package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.monitor.ResourceFormat

/**
 * Guardia antes de arrancar otro `claude` en un servidor (port de
 * `ArgosCore/Agent/AgentLaunchGuard.swift`). Cada `claude` ocupa ~0,5 GB y el servidor del
 * usuario ya se quedó una vez sin memoria por acumularlos: con poca memoria libre o demasiados
 * agentes vivos se AVISA y se deja seguir bajo confirmación.
 */
object AgentLaunchGuard {

    /** Por debajo de esto no se arranca un agente sin confirmación (KB). */
    const val MINIMUM_FREE_MEMORY_KB = 900_000L

    /** Agentes vivos a partir de los cuales se pide confirmación (en todo el servidor). */
    const val MAX_LIVE_AGENTS = 6

    sealed interface Assessment {
        data object Ok : Assessment

        /** Hay que confirmar: [title] para el aviso y [message] con el porqué. */
        data class Warning(val title: String, val message: String) : Assessment
    }

    /** [freeMemoryKB] `null` = no se sabe (servidor no Linux): no se avisa por memoria. */
    fun assess(freeMemoryKB: Long?, liveAgents: Int): Assessment {
        if (freeMemoryKB != null && freeMemoryKB < MINIMUM_FREE_MEMORY_KB) {
            return Assessment.Warning(
                "Poca memoria libre en el servidor",
                "Quedan ${ResourceFormat.kilobytes(freeMemoryKB)} libres y cada agente de Claude ocupa unos 0,5 GB. " +
                    "Detén o hiberna agentes que no uses para liberar memoria.",
            )
        }
        if (liveAgents >= MAX_LIVE_AGENTS) {
            return Assessment.Warning(
                "Ya hay $liveAgents agentes en marcha",
                "Cada agente de Claude ocupa unos 0,5 GB en el servidor. " +
                    "Detén o hiberna alguno antes de abrir otro, o continúa si sabes que hay memoria.",
            )
        }
        return Assessment.Ok
    }
}
