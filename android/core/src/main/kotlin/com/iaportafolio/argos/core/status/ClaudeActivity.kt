package com.iaportafolio.argos.core.status

import com.iaportafolio.argos.core.agent.SwiftText

/*
 * Estado de Claude Code dentro de los paneles de tmux (port de
 * `ArgosCore/ClaudeStatus/ClaudeActivity.swift`). Los hooks instalados por
 * [ClaudeHookInstaller] escriben la opción de panel `@argos_claude`; Argos la lee con
 * [ClaudeStatusCommands.CLAUDE_ACTIVITY_COMMAND]. El nombre de sesión va AL FINAL para
 * tolerar '|' dentro de él.
 */

/** Qué está haciendo Claude Code en un panel. */
enum class ClaudeActivity(val rawValue: String, val priority: Int, val label: String) {
    /** Procesando (tras un prompt o una herramienta). */
    WORKING("working", 1, "Claude trabajando"),

    /** Necesita al usuario: permiso, pregunta o diálogo. */
    WAITING("waiting", 3, "Claude espera tu respuesta"),

    /** Terminó de responder; espera el siguiente prompt. */
    DONE("done", 2, "Claude terminó"),
    ;

    companion object {
        fun fromRaw(raw: String): ClaudeActivity? = entries.firstOrNull { it.rawValue == raw }
    }
}

/** Paso a un estado que merece aviso (esperando o terminó) en una sesión. */
data class ClaudeTransition(val session: String, val activity: ClaudeActivity)

/** Estado de Claude en todas las sesiones de un servidor, agregado por sesión y ventana. */
class ClaudeActivitySnapshot private constructor(
    /** sesión -> índice de ventana -> estado (agregado si hay varios paneles). */
    private val bySession: Map<String, Map<Int, ClaudeActivity>>,
) {

    /** Estado agregado de la sesión (el de mayor prioridad entre sus ventanas). */
    fun activity(session: String): ClaudeActivity? = bySession[session]?.values?.maxByOrNull { it.priority }

    /** Estado más urgente entre varias sesiones (p. ej. un grupo colapsado). */
    fun activity(sessions: List<String>): ClaudeActivity? =
        sessions.mapNotNull(::activity).maxByOrNull { it.priority }

    /** Estado por índice de ventana de la sesión. */
    fun windows(session: String): Map<Int, ClaudeActivity> = bySession[session] ?: emptyMap()

    /** Sesiones que ENTRARON en «esperando» o «terminó» respecto a [previous]. */
    fun notableTransitions(previous: ClaudeActivitySnapshot): List<ClaudeTransition> =
        bySession.keys.sorted().mapNotNull { session ->
            val now = activity(session) ?: return@mapNotNull null
            val notable = (now == ClaudeActivity.WAITING || now == ClaudeActivity.DONE) && previous.activity(session) != now
            if (notable) ClaudeTransition(session, now) else null
        }

    override fun equals(other: Any?): Boolean = other is ClaudeActivitySnapshot && other.bySession == bySession

    override fun hashCode(): Int = bySession.hashCode()

    override fun toString(): String = "ClaudeActivitySnapshot($bySession)"

    companion object {
        val EMPTY = ClaudeActivitySnapshot(emptyMap())

        /** Parsea la salida de `list-panes`; ignora paneles sin estado o con valores desconocidos. */
        fun fromListPanes(output: String): ClaudeActivitySnapshot {
            val parsed = SwiftText.lines(output).mapNotNull { line ->
                val fields = line.split("|", limit = 3)
                if (fields.size != 3 || fields[2].isEmpty()) return@mapNotNull null
                val activity = ClaudeActivity.fromRaw(fields[0]) ?: return@mapNotNull null
                val window = fields[1].toIntOrNull() ?: return@mapNotNull null
                Triple(fields[2], window, activity)
            }
            val bySession = parsed.groupBy({ it.first }) { it.second to it.third }.mapValues { (_, panes) ->
                panes.groupBy({ it.first }) { it.second }
                    .mapValues { (_, activities) -> activities.reduce { kept, next -> if (next.priority > kept.priority) next else kept } }
            }
            return ClaudeActivitySnapshot(bySession)
        }
    }
}
