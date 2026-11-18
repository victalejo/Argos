package com.iaportafolio.argos.core.status

import com.iaportafolio.argos.core.agent.SwiftText

/*
 * Estado de Claude Code dentro de los paneles de tmux (port de
 * `ArgosCore/ClaudeStatus/ClaudeActivity.swift`). Los hooks instalados por
 * [ClaudeHookInstaller] escriben la opción de panel `@argos_claude`; Argos la lee con
 * [ClaudeStatusCommands.CLAUDE_ACTIVITY_COMMAND], una línea por panel:
 *     <pantalla>|<estado>|<pane_id>|<window_index>|<session_name>
 * El nombre de sesión va AL FINAL para tolerar '|' dentro de él.
 *
 * Los hooks no lo cubren todo: interrumpir con Esc no dispara `Stop` y tras aprobar un permiso no
 * hay evento hasta que acaba la herramienta. Se corrige con lo que muestra la pantalla
 * ([ClaudeScreenSignal]).
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

/** Lo que se ve en la pantalla del panel (solo se mira en paneles working/waiting). */
enum class ClaudeScreenSignal(val rawValue: String) {
    /** No se miró la pantalla. */
    UNCHECKED("-"),

    /** Ni spinner ni «esc to interrupt»: Claude está parado. */
    IDLE("0"),

    /** Línea del spinner (`✻ Pensando… (12s · …)`): señal débil. */
    SPINNER("1"),

    /** «esc to interrupt» en el pie: seguro que está trabajando. */
    BUSY("2"),
    ;

    companion object {
        fun fromRaw(raw: String): ClaudeScreenSignal = entries.firstOrNull { it.rawValue == raw } ?: UNCHECKED
    }
}

/** Paso a un estado que merece aviso (esperando o terminó) en una ventana. */
data class ClaudeTransition(val session: String, val window: Int, val activity: ClaudeActivity)

/** Estado de Claude en un panel, ya corregido con la pantalla. */
data class ClaudePaneActivity(
    val paneId: String,
    val session: String,
    val window: Int,
    val activity: ClaudeActivity,
    /** Llegó a `done` porque se interrumpió (o murió sin `SessionEnd`): no se avisa. */
    val isQuiet: Boolean,
) {
    companion object {
        /**
         * Corrige el estado de los hooks con la pantalla: `working` sin rastro de trabajo es una
         * interrupción (`done` silencioso); `waiting` con «esc to interrupt» ya está trabajando.
         */
        fun resolve(hook: ClaudeActivity, screen: ClaudeScreenSignal): Pair<ClaudeActivity, Boolean> = when {
            hook == ClaudeActivity.WORKING && screen == ClaudeScreenSignal.IDLE -> ClaudeActivity.DONE to true
            hook == ClaudeActivity.WAITING && screen == ClaudeScreenSignal.BUSY -> ClaudeActivity.WORKING to false
            else -> hook to false
        }
    }
}

/** Estado de Claude en todas las sesiones de un servidor (un elemento por panel con estado). */
data class ClaudeActivitySnapshot(val panes: List<ClaudePaneActivity>) {

    /** Estado agregado de la sesión (el de mayor prioridad entre sus paneles). */
    fun activity(session: String): ClaudeActivity? = mostUrgent(panes.filter { it.session == session }.map { it.activity })

    /** Estado más urgente entre varias sesiones (p. ej. un grupo colapsado). */
    fun activity(sessions: List<String>): ClaudeActivity? {
        val wanted = sessions.toSet()
        return mostUrgent(panes.filter { it.session in wanted }.map { it.activity })
    }

    /** Estado por índice de ventana de la sesión (agregado si hay varios paneles). */
    fun windows(session: String): Map<Int, ClaudeActivity> = panes.filter { it.session == session }
        .fold(emptyMap()) { result, pane ->
            val kept = result[pane.window]
            if (kept == null || pane.activity.priority > kept.priority) result + (pane.window to pane.activity) else result
        }

    /**
     * Paneles que ENTRARON en «esperando» o «terminó» respecto a [previous], panel a panel (otra
     * ventana ya terminada no oculta el aviso de esta). Lo silencioso no se avisa; dos paneles de
     * la misma ventana dan un solo aviso.
     */
    fun notableTransitions(previous: ClaudeActivitySnapshot): List<ClaudeTransition> {
        val before = previous.panes.reversed().associate { it.paneId to it.activity }
        val seen = mutableSetOf<Pair<String, Int>>()
        return panes.mapNotNull { pane ->
            val notable = !pane.isQuiet &&
                (pane.activity == ClaudeActivity.WAITING || pane.activity == ClaudeActivity.DONE) &&
                before[pane.paneId] != pane.activity
            if (notable && seen.add(pane.session to pane.window)) ClaudeTransition(pane.session, pane.window, pane.activity) else null
        }
    }

    companion object {
        val EMPTY = ClaudeActivitySnapshot(emptyList())

        /** Parsea la salida del sondeo; ignora paneles sin estado o con valores desconocidos. */
        fun fromListPanes(output: String): ClaudeActivitySnapshot = ClaudeActivitySnapshot(
            SwiftText.lines(output).mapNotNull { line ->
                val fields = line.split("|", limit = 5)
                if (fields.size != 5) return@mapNotNull null
                val hook = ClaudeActivity.fromRaw(fields[1]) ?: return@mapNotNull null
                val window = fields[3].toIntOrNull() ?: return@mapNotNull null
                if (fields[2].isEmpty() || fields[4].isEmpty()) return@mapNotNull null
                val (activity, quiet) = ClaudePaneActivity.resolve(hook, ClaudeScreenSignal.fromRaw(fields[0]))
                ClaudePaneActivity(fields[2], fields[4], window, activity, quiet)
            },
        )

        private fun mostUrgent(activities: List<ClaudeActivity>): ClaudeActivity? = activities.maxByOrNull { it.priority }
    }
}
