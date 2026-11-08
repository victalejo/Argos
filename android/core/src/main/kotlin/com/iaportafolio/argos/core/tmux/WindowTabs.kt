package com.iaportafolio.argos.core.tmux

import java.util.Locale

/** Qué hacer cuando el usuario pide cerrar una ventana (port de `WindowCloseDecision`). */
enum class WindowCloseDecision {
    /** Es la última ventana: cerrarla mataría la sesión entera, así que no se hace. */
    BLOCKED,

    /** La ventana solo tiene un shell ocioso: se cierra sin preguntar. */
    IMMEDIATE,

    /** Hay algo corriendo (un agente, un servidor, varios paneles…): se confirma. */
    CONFIRM,
}

/**
 * Lógica pura de las pestañas de ventanas tmux (port de `ArgosCore/Tabs/WindowTabs.swift`):
 * título, agente de cada una, a qué ventana saltan los atajos y si cerrar necesita confirmación.
 */
object WindowTabs {
    private const val MAX_SHORTCUT = 9

    /** Procesos que cuentan como «shell ocioso» (nada que perder al cerrar). */
    val SHELL_COMMANDS: Set<String> = setOf("sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "ash", "nu")

    /** ¿[command] es un shell sin nada en primer plano? Tolera el guion de los shells de login (`-zsh`). */
    fun isIdleShell(command: String?): Boolean {
        if (command == null) return false
        return command.removePrefix("-").lowercase(Locale.ROOT) in SHELL_COMMANDS
    }

    /** Decide cómo cerrar [window] sabiendo cuántas ventanas tiene la sesión. */
    fun closeDecision(window: TmuxWindow, totalWindows: Int): WindowCloseDecision = when {
        totalWindows <= 1 -> WindowCloseDecision.BLOCKED
        window.paneCount == 1 && isIdleShell(window.currentCommand) -> WindowCloseDecision.IMMEDIATE
        else -> WindowCloseDecision.CONFIRM
    }

    /**
     * Posición (0…count-1) para el atajo N (1…9). Como en los navegadores, 9 salta siempre a la
     * última. `null` si no hay tantas pestañas.
     */
    fun position(shortcut: Int, count: Int): Int? = when {
        shortcut !in 1..MAX_SHORTCUT || count <= 0 -> null
        shortcut == MAX_SHORTCUT -> count - 1
        shortcut - 1 < count -> shortcut - 1
        else -> null
    }

    /**
     * Posición a [offset] de [current] (−1 anterior, +1 siguiente), dando la vuelta en los
     * extremos. `null` si hay menos de dos pestañas.
     */
    fun adjacentPosition(current: Int, offset: Int, count: Int): Int? =
        if (count > 1) Math.floorMod(current + offset, count) else null

    /** Ventana para el atajo N (1…9; 9 = la última). */
    fun windowAtShortcut(shortcut: Int, windows: List<TmuxWindow>): TmuxWindow? =
        position(shortcut, windows.size)?.let { windows[it] }

    /** Ventana anterior/siguiente a la activa, dando la vuelta en los extremos. */
    fun adjacent(windows: List<TmuxWindow>, offset: Int): TmuxWindow? {
        val current = windows.indexOfFirst { it.isActive }.coerceAtLeast(0)
        return adjacentPosition(current, offset, windows.size)?.let { windows[it] }
    }

    /** Agente de la ventana: por su proceso/nombre o, si los hooks de Claude lo informan, Claude Code. */
    fun agent(window: TmuxWindow, claudeReported: Boolean): CodingAgent? =
        CodingAgent.detect(window.currentCommand, window.name) ?: if (claudeReported) CodingAgent.CLAUDE else null

    /**
     * Título de la pestaña: el nombre del agente, el nombre de la ventana o `null` cuando el
     * nombre es solo el del shell (la pestaña muestra entonces `>_ 1`).
     */
    fun title(window: TmuxWindow, agent: CodingAgent?): String? = when {
        agent != null -> agent.displayName
        isIdleShell(window.name) -> null
        else -> window.name
    }

    /** Agentes que corren en más de una ventana: sus pestañas llevan también el número de ventana. */
    fun repeatedAgents(windows: List<TmuxWindow>, claudeReported: Set<Int>): Set<CodingAgent> = windows
        .mapNotNull { agent(it, claudeReported = it.index in claudeReported) }
        .groupingBy { it }
        .eachCount()
        .filterValues { it > 1 }
        .keys
}
