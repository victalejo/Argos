package com.iaportafolio.argos.core.tmux

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import kotlin.test.Test
import kotlin.test.assertEquals

/** Paridad con `ArgosTests/TmuxPaneTests.swift`, más los comandos de panel. */
class TmuxPaneTest {

    @ParameterizedTest
    @CsvSource("UP,-U", "DOWN,-D", "LEFT,-L", "RIGHT,-R")
    fun `selectPaneFlag mapea cada direccion a su flag de tmux`(direction: TmuxPaneDirection, expected: String) {
        assertEquals(expected, direction.selectPaneFlag)
    }

    @Test
    fun `hay exactamente cuatro direcciones`() {
        assertEquals(4, TmuxPaneDirection.entries.size)
    }

    @Test
    fun `comandos de panel identicos a Apple`() {
        assertEquals("tmux split-window -v -t 'a b'", TmuxCommands.splitPane("a b", vertical = true))
        assertEquals("tmux split-window -h -t 'a b'", TmuxCommands.splitPane("a b", vertical = false))
        assertEquals("tmux select-pane -L -t 'dev'", TmuxCommands.selectPane("dev", TmuxPaneDirection.LEFT))
        assertEquals("tmux resize-pane -Z -t 'dev'", TmuxCommands.zoomPane("dev"))
        assertEquals("tmux kill-pane -t 'dev'", TmuxCommands.killPane("dev"))
    }
}
