package com.iaportafolio.argos.core.agent

import java.time.Duration
import java.time.Instant

/** Texto de una notificación local (título y cuerpo). */
data class AgentNotificationText(val title: String, val body: String)

/**
 * ¿Necesita un agente persistente tu atención? Se decide leyendo el FINAL de su log
 * (port de `ArgosCore/Agent/AgentAttention.swift`): pide permiso si hay un
 * `control_request` sin responder, o terminó si lo último relevante es un `result`.
 */
sealed interface AgentAttention {
    data object None : AgentAttention
    data class NeedsPermission(val tool: String) : AgentAttention
    data class Finished(val summary: String?, val isError: Boolean) : AgentAttention

    /** Texto breve para una notificación (o `null` si no hay nada que avisar). */
    fun notification(agentTitle: String): AgentNotificationText? = when (this) {
        is None -> null
        is NeedsPermission -> AgentNotificationText(
            "$agentTitle: Claude espera tu permiso",
            "Quiere usar $tool. Ábrelo para permitir o denegar.",
        )
        is Finished -> AgentNotificationText(
            "$agentTitle: ${if (isError) "Claude terminó con error" else "Claude terminó"}",
            summary?.let { SwiftText.graphemePrefix(it, SUMMARY_MAX_CHARACTERS) }
                ?: if (isError) "Terminó con un error." else "Terminó la tarea.",
        )
    }

    companion object {
        private const val SUMMARY_MAX_CHARACTERS = 180

        /** Estado del agente según las últimas líneas de su log. */
        fun evaluate(logTail: String): AgentAttention {
            var pending: AgentPermissionRequest? = null
            var outcome: AgentAttention = None
            // La primera línea puede venir cortada (es un trozo del final): se ignora si no
            // parsea, igual que cualquier ruido.
            for (line in SwiftText.lines(logTail)) {
                when (val event = AgentProtocol.decode(line) ?: continue) {
                    is AgentStreamEvent.PermissionRequest -> {
                        pending = event.request
                        outcome = None
                    }
                    is AgentStreamEvent.PermissionCancel -> if (pending?.id == event.requestID) pending = null
                    is AgentStreamEvent.Result -> {
                        pending = null
                        outcome = Finished(event.result.text, event.result.isError)
                    }
                    is AgentStreamEvent.User ->
                        if (event.blocks.any { it is AgentContentBlock.Text }) outcome = None // prompt nuevo: trabaja
                    is AgentStreamEvent.Initialized, is AgentStreamEvent.Assistant,
                    is AgentStreamEvent.RateLimit, is AgentStreamEvent.Ignored,
                    -> Unit
                }
            }
            return pending?.let { NeedsPermission(it.displayName ?: it.toolName) } ?: outcome
        }
    }
}

/** Instantánea de un agente para los avisos: tamaño del log y su final. */
data class AgentLogSnapshot(
    val id: String,
    val isAlive: Boolean,
    val logBytes: Long,
    val title: String,
    val createdAt: Instant,
    val tail: String,
)

/**
 * Decide qué avisar comparando con lo ya visto (tamaño del log por agente): solo se avisa
 * de lo NUEVO, una vez.
 */
object AgentAttentionPlanner {

    data class Notice(val agentID: String, val title: String, val body: String)

    /** Resultado de [notices]: los avisos y lo visto actualizado. */
    data class Plan(val notices: List<Notice>, val seen: Map<String, Long>)

    /**
     * Un agente nunca visto pero creado hace menos de esto se considera nuevo (se avisa de
     * lo que haya hecho); uno más viejo solo se toma como referencia.
     */
    val recentAgentWindow: Duration = Duration.ofHours(24)

    /** [seenBytes]: lo ya visto de los agentes de UN servidor. */
    fun notices(
        snapshots: List<AgentLogSnapshot>,
        seenBytes: Map<String, Long>,
        now: Instant = Instant.now(),
    ): Plan {
        val notices = snapshots.mapNotNull { snapshot ->
            val isRecent = Duration.between(snapshot.createdAt, now) < recentAgentWindow
            val previous = seenBytes[snapshot.id] ?: if (isRecent) 0L else null
            if (previous == null || snapshot.logBytes <= previous) return@mapNotNull null
            AgentAttention.evaluate(snapshot.tail).notification(snapshot.title)
                ?.let { Notice(snapshot.id, it.title, it.body) }
        }
        // Lo visto se actualiza con todos los presentes y se olvidan los que ya no existen.
        val present = snapshots.map { it.id }.toSet()
        val seen = seenBytes.filterKeys { it in present } + snapshots.associate { it.id to it.logBytes }
        return Plan(notices, seen)
    }
}
