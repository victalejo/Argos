package com.iaportafolio.argos.core.tmux

import com.iaportafolio.argos.core.ShellQuoting
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * Paridad con `ArgosTests/SendKeysTests.swift`: el texto va entrecomillado para el shell y
 * `Enter` como argumento aparte (sin comillas) para que tmux lo interprete como tecla.
 */
class SendKeysTest {

    @Test
    fun `comando basico con Enter`() {
        assertEquals("tmux send-keys -t 'main' 'git pull' Enter", TmuxCommands.sendKeys("main", "git pull", enter = true))
    }

    @Test
    fun `sin Enter no anade la tecla`() {
        val cmd = TmuxCommands.sendKeys("main", "ls -la", enter = false)
        assertEquals("tmux send-keys -t 'main' 'ls -la'", cmd)
        assertFalse(cmd.endsWith("Enter"))
    }

    @Test
    fun `sesion y texto se entrecomillan con ShellQuoting`() {
        val session = "team's-box"
        val keys = "echo 'hola'; rm -rf nope"
        val expected = "tmux send-keys -t ${ShellQuoting.singleQuoted(session)} " + ShellQuoting.singleQuoted(keys) + " Enter"
        assertEquals(expected, TmuxCommands.sendKeys(session, keys, enter = true))
    }

    @Test
    fun `metacaracteres del shell quedan literales dentro de las comillas`() {
        assertEquals(
            "tmux send-keys -t 's' '\$(whoami) && reboot'",
            TmuxCommands.sendKeys("s", "\$(whoami) && reboot", enter = false),
        )
    }
}
