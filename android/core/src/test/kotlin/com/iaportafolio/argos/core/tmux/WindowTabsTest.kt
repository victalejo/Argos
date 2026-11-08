package com.iaportafolio.argos.core.tmux

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/WindowTabsTests.swift` (dependencia de [CodingAgent.detect]). */
class WindowTabsTest {

    private fun window(
        index: Int,
        name: String = "zsh",
        active: Boolean = false,
        panes: Int = 1,
        command: String? = "zsh",
    ) = TmuxWindow(index, name, isActive = active, paneCount = panes, currentCommand = command)

    @Test
    fun `la ultima ventana no se cierra`() {
        assertEquals(WindowCloseDecision.BLOCKED, WindowTabs.closeDecision(window(0), totalWindows = 1))
    }

    @ParameterizedTest
    @ValueSource(strings = ["zsh", "bash", "-zsh", "fish", "sh"])
    fun `un shell ocioso se cierra sin preguntar`(command: String) {
        assertEquals(WindowCloseDecision.IMMEDIATE, WindowTabs.closeDecision(window(1, command = command), totalWindows = 2))
    }

    @ParameterizedTest
    @ValueSource(strings = ["claude", "vim", "node"])
    fun `con algo corriendo se pide confirmacion`(command: String) {
        assertEquals(WindowCloseDecision.CONFIRM, WindowTabs.closeDecision(window(1, command = command), totalWindows = 2))
    }

    @Test
    fun `varios paneles o comando desconocido piden confirmacion`() {
        assertEquals(WindowCloseDecision.CONFIRM, WindowTabs.closeDecision(window(1, panes = 2), totalWindows = 3))
        assertEquals(WindowCloseDecision.CONFIRM, WindowTabs.closeDecision(window(1, command = null), totalWindows = 3))
    }

    @Test
    fun `el atajo salta por posicion, no por indice de tmux`() {
        val windows = listOf(window(1), window(3), window(7))
        assertEquals(1, WindowTabs.windowAtShortcut(1, windows)?.index)
        assertEquals(3, WindowTabs.windowAtShortcut(2, windows)?.index)
        assertNull(WindowTabs.windowAtShortcut(4, windows))
    }

    @Test
    fun `el atajo 9 es siempre la ultima pestana`() {
        assertEquals(2, WindowTabs.windowAtShortcut(9, listOf(window(0), window(1), window(2)))?.index)
    }

    @ParameterizedTest
    @ValueSource(ints = [0, 10, -1])
    fun `atajos fuera de rango o sin ventanas no hacen nada`(number: Int) {
        assertNull(WindowTabs.position(number, count = 3))
        assertNull(WindowTabs.position(1, count = 0))
    }

    @Test
    fun `anterior y siguiente dan la vuelta en los extremos`() {
        val windows = listOf(window(0), window(1), window(2, active = true))
        assertEquals(0, WindowTabs.adjacent(windows, offset = 1)?.index)
        assertEquals(1, WindowTabs.adjacent(windows, offset = -1)?.index)
        assertEquals(2, WindowTabs.adjacentPosition(current = 0, offset = -1, count = 3))
    }

    @Test
    fun `con una sola pestana no hay anterior ni siguiente`() {
        assertNull(WindowTabs.adjacent(listOf(window(0, active = true)), offset = 1))
    }

    @Test
    fun `los hooks de Claude marcan la ventana como Claude Code`() {
        assertEquals(CodingAgent.CLAUDE, WindowTabs.agent(window(1, command = "node"), claudeReported = true))
        assertNull(WindowTabs.agent(window(1, command = "node"), claudeReported = false))
    }

    @Test
    fun `titulo es el agente, el nombre propio o nada si es el shell`() {
        assertEquals("Grok", WindowTabs.title(window(1), CodingAgent.GROK))
        assertEquals("servidor", WindowTabs.title(window(1, name = "servidor"), null))
        assertNull(WindowTabs.title(window(1, name = "zsh"), null))
    }

    @Test
    fun `solo los agentes repetidos llevan numero`() {
        val windows = listOf(
            window(0, command = "claude"), window(1, command = "claude"),
            window(2, command = "codex"), window(3, command = "node"),
        )
        assertEquals(setOf(CodingAgent.CLAUDE), WindowTabs.repeatedAgents(windows, claudeReported = emptySet()))
        assertEquals(setOf(CodingAgent.CLAUDE), WindowTabs.repeatedAgents(windows, claudeReported = setOf(3)))
        assertTrue(WindowTabs.repeatedAgents(listOf(window(0, command = "grok")), claudeReported = emptySet()).isEmpty())
    }
}
