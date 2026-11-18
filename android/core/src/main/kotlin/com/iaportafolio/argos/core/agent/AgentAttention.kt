package com.iaportafolio.argos.core.agent

import java.time.Duration
import java.time.Instant

/** Texto de una notificación local (título y cuerpo). */
data class AgentNotificationText(val title: String, val body: String)

/**
 * ¿Necesita un agente persistente tu atención? Se decide leyendo el FINAL de su log (port de
 * `ArgosCore/Agent/AgentAttention.swift`): pide permiso si hay un `control_request` sin
 * responder, o terminó si lo último relevante es un `result`.
 *
 * El final llega como las últimas líneas RECORTADAS (ver [PersistentAgentScript.snapshots]): un
 * permiso de un `Write` enorme no cabe entero, así que lo que no es JSON válido se lee de forma
 * tolerante ([AgentLogLineSummary]). Si algo no se pudo evaluar, no se da por visto.
 */
sealed interface AgentAttention {
    data object None : AgentAttention
    data class NeedsPermission(val tool: String) : AgentAttention
    data class Finished(val summary: String?, val isError: Boolean) : AgentAttention

    /**
     * El final del log no se pudo interpretar (p. ej. un permiso sin `request_id` legible): no
     * se avisa, pero tampoco se marca como visto.
     */
    data object Undetermined : AgentAttention

    /** Texto breve para una notificación (o `null` si no hay nada que avisar). */
    fun notification(agentTitle: String): AgentNotificationText? = when (this) {
        is None, is Undetermined -> null
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
            var pending: AgentLogLineSummary? = null
            var outcome: AgentAttention = None
            var recognized = false
            var unreadablePermission = false
            for (raw in SwiftText.lines(logTail)) {
                val line = AgentLogLineSummary.of(raw) ?: continue
                recognized = true
                when (line.kind) {
                    AgentLogLineSummary.Kind.PERMISSION_REQUEST -> {
                        val readable = line.requestID != null && line.toolName != null
                        unreadablePermission = !readable
                        pending = if (readable) line else null
                        outcome = None
                    }
                    AgentLogLineSummary.Kind.PERMISSION_ANSWERED, AgentLogLineSummary.Kind.PERMISSION_CANCEL -> {
                        if (pending?.requestID == line.requestID) pending = null
                        if (line.requestID != null) unreadablePermission = false
                    }
                    AgentLogLineSummary.Kind.RESULT -> {
                        pending = null
                        unreadablePermission = false
                        outcome = Finished(line.resultText, line.isError)
                    }
                    AgentLogLineSummary.Kind.USER_PROMPT -> outcome = None // un prompt nuevo: vuelve a trabajar
                    AgentLogLineSummary.Kind.OTHER -> Unit
                }
            }
            val tool = pending?.toolName
            return when {
                tool != null -> NeedsPermission(pending.displayName ?: tool)
                unreadablePermission -> Undetermined
                !recognized && SwiftText.trimWhitespaceAndNewlines(logTail).isNotEmpty() -> Undetermined
                else -> outcome
            }
        }
    }
}

/**
 * Lo que importa de una línea del log, aunque venga recortada. Primero se intenta decodificar
 * entera; si no es JSON válido, se extraen los campos con lecturas tolerantes (las comillas de
 * dentro de las cadenas JSON van escapadas, así que `"type":"…"` literal es siempre una clave).
 */
data class AgentLogLineSummary(
    val kind: Kind,
    val requestID: String? = null,
    val toolName: String? = null,
    val displayName: String? = null,
    val isError: Boolean = false,
    val resultText: String? = null,
) {
    enum class Kind { PERMISSION_REQUEST, PERMISSION_ANSWERED, PERMISSION_CANCEL, RESULT, USER_PROMPT, OTHER }

    companion object {
        /** `null` si la línea no tiene ni un `type` reconocible. */
        fun of(line: String): AgentLogLineSummary? {
            AgentProtocol.decode(line)?.let { return fromEvent(it) }
            val type = firstString("\"type\":", line) ?: return null
            return fromCutLine(type, line)
        }

        private fun fromEvent(event: AgentStreamEvent): AgentLogLineSummary = when (event) {
            is AgentStreamEvent.PermissionRequest -> AgentLogLineSummary(
                Kind.PERMISSION_REQUEST,
                requestID = event.request.id,
                toolName = event.request.toolName,
                displayName = event.request.displayName,
            )
            is AgentStreamEvent.PermissionCancel -> AgentLogLineSummary(Kind.PERMISSION_CANCEL, requestID = event.requestID)
            is AgentStreamEvent.Result -> AgentLogLineSummary(
                Kind.RESULT,
                isError = event.result.isError,
                resultText = event.result.text,
            )
            is AgentStreamEvent.User ->
                AgentLogLineSummary(if (event.blocks.any { it is AgentContentBlock.Text }) Kind.USER_PROMPT else Kind.OTHER)
            is AgentStreamEvent.Initialized, is AgentStreamEvent.Assistant,
            is AgentStreamEvent.RateLimit, is AgentStreamEvent.Ignored,
            -> AgentLogLineSummary(Kind.OTHER)
        }

        /** Lectura tolerante de una línea que no es JSON válido (recortada). */
        private fun fromCutLine(type: String, line: String): AgentLogLineSummary = when (type) {
            "control_request" ->
                // Solo cuentan los permisos (otras peticiones de control no esperan al usuario).
                if (line.contains("\"can_use_tool\"") || !line.contains("\"subtype\":")) {
                    AgentLogLineSummary(
                        Kind.PERMISSION_REQUEST,
                        requestID = firstString("\"request_id\":", line),
                        toolName = firstString("\"tool_name\":", line),
                        displayName = firstString("\"display_name\":", line),
                    )
                } else {
                    AgentLogLineSummary(Kind.OTHER)
                }
            PersistentAgentScript.ANSWERED_EVENT_TYPE ->
                AgentLogLineSummary(Kind.PERMISSION_ANSWERED, requestID = firstString("\"request_id\":", line))
            "control_cancel_request" ->
                AgentLogLineSummary(Kind.PERMISSION_CANCEL, requestID = firstString("\"request_id\":", line))
            "result" -> AgentLogLineSummary(
                Kind.RESULT,
                isError = line.contains("\"is_error\":true"),
                resultText = firstString("\"result\":", line),
            )
            "user" -> {
                // Recortada no se sabe si es un prompt o un resultado de herramienta: los
                // resultados llevan `tool_result` cerca del principio.
                val isToolResult = line.contains("\"tool_result\"") || line.contains("\"tool_use_id\"")
                val isSecondary = line.contains("\"isMeta\":true") || line.contains("\"isSynthetic\":true")
                AgentLogLineSummary(if (isToolResult || isSecondary) Kind.OTHER else Kind.USER_PROMPT)
            }
            else -> AgentLogLineSummary(Kind.OTHER)
        }

        /**
         * Valor de cadena que sigue a [key] (p. ej. `"type":`), tolerando espacios y desescapando
         * lo básico. `null` si no aparece o la cadena está cortada.
         */
        fun firstString(key: String, line: String): String? {
            val keyIndex = line.indexOf(key)
            if (keyIndex < 0) return null
            var index = keyIndex + key.length
            while (index < line.length && line[index] == ' ') index++
            if (index >= line.length || line[index] != '"') return null
            index++
            val value = StringBuilder()
            var escaping = false
            while (index < line.length) {
                val character = line[index]
                when {
                    escaping -> {
                        value.append(
                            when (character) {
                                'n' -> '\n'
                                't' -> '\t'
                                else -> character
                            },
                        )
                        escaping = false
                    }
                    character == '\\' -> escaping = true
                    character == '"' -> return value.toString()
                    else -> value.append(character)
                }
                index++
            }
            return null
        }
    }
}

/** Instantánea de un agente para los avisos: tamaño del log y su final. */
data class AgentLogSnapshot(
    val id: String,
    val isAlive: Boolean,
    /** Bytes ABSOLUTOS del log (incluidos los rotados). */
    val logBytes: Long,
    val title: String,
    val createdAt: Instant,
    val tail: String,
)

/**
 * Decide qué avisar comparando con lo ya visto (tamaño del log por agente): solo se avisa de lo
 * NUEVO, una vez.
 */
object AgentAttentionPlanner {

    data class Notice(val agentID: String, val title: String, val body: String)

    /** Resultado de [notices]: los avisos y lo visto actualizado. */
    data class Plan(val notices: List<Notice>, val seen: Map<String, Long>)

    /**
     * Un agente nunca visto pero creado hace menos de esto se considera nuevo (se avisa de lo que
     * haya hecho); uno más viejo solo se toma como referencia.
     */
    val recentAgentWindow: Duration = Duration.ofHours(24)

    /** [seenBytes]: lo ya visto de los agentes de UN servidor. */
    fun notices(
        snapshots: List<AgentLogSnapshot>,
        seenBytes: Map<String, Long>,
        now: Instant = Instant.now(),
    ): Plan {
        val notices = mutableListOf<Notice>()
        val seen = seenBytes.toMutableMap()
        for (snapshot in snapshots) {
            val isRecent = Duration.between(snapshot.createdAt, now) < recentAgentWindow
            val previous = seenBytes[snapshot.id] ?: if (isRecent) 0L else null
            if (previous == null || snapshot.logBytes <= previous) {
                seen[snapshot.id] = snapshot.logBytes
                continue
            }
            val attention = AgentAttention.evaluate(snapshot.tail)
            // Lo que no se pudo evaluar se deja SIN ver: el próximo refresco lo reintenta.
            if (attention == AgentAttention.Undetermined) continue
            seen[snapshot.id] = snapshot.logBytes
            attention.notification(snapshot.title)?.let { notices += Notice(snapshot.id, it.title, it.body) }
        }
        // Olvidar agentes que ya no existen.
        val present = snapshots.map { it.id }.toSet()
        return Plan(notices, seen.filterKeys { it in present })
    }
}
