package com.iaportafolio.argos.core.tmux

import com.iaportafolio.argos.core.SSHServiceError
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Paridad con `ArgosTests/TmuxErrorClassificationTests.swift`, más la decisión completa de
 * `listSessions`/`listWindows`/`runManagementCommand` portada a [TmuxOutputParser].
 */
class TmuxErrorClassificationTest {

    @ParameterizedTest
    @ValueSource(
        strings = [
            "no server running on /tmp/tmux-1000/default",
            "error connecting to /tmp/tmux-1000/default (No such file or directory)",
            "failed to connect to server",
            "no sessions",
        ],
    )
    fun `marcadores de no hay servidor significan lista vacia`(stderr: String) {
        assertTrue(TmuxOutputParser.indicatesNoTmuxServer(stdout = "", stderr = stderr))
        assertEquals(emptyList(), TmuxOutputParser.parseListSessions(stdout = "", stderr = stderr, exitCode = 1))
    }

    @Test
    fun `salida normal no se confunde con no hay servidor`() {
        assertFalse(TmuxOutputParser.indicatesNoTmuxServer(stdout = "main|1|0|1700000000", stderr = ""))
    }

    @Test
    fun `command not found significa tmux no instalado`() {
        assertTrue(TmuxOutputParser.indicatesTmuxNotInstalled("", "bash: tmux: command not found", 127))
    }

    @Test
    fun `exit 127 mencionando tmux significa no instalado`() {
        assertTrue(TmuxOutputParser.indicatesTmuxNotInstalled("", "tmux: not found", 127))
    }

    @Test
    fun `un error real no relacionado no se clasifica como tmux ausente`() {
        assertFalse(TmuxOutputParser.indicatesTmuxNotInstalled("", "permission denied", 1))
    }

    @Test
    fun `list-sessions con tmux ausente lanza TmuxNotInstalled`() {
        assertFailsWith<SSHServiceError.TmuxNotInstalled> {
            TmuxOutputParser.parseListSessions("", "bash: tmux: command not found", 127)
        }
    }

    @Test
    fun `list-sessions con otro fallo lanza CommandFailed con el stderr`() {
        val error = assertFailsWith<SSHServiceError.CommandFailed> {
            TmuxOutputParser.parseListSessions("", "  permission denied\n", 1)
        }
        assertEquals(1, error.exitCode)
        assertEquals("El comando remoto falló (código 1): permission denied", error.message)
    }

    @Test
    fun `list-sessions con fallo sin stderr usa el mensaje por defecto`() {
        val error = assertFailsWith<SSHServiceError.CommandFailed> { TmuxOutputParser.parseListSessions("", "", 2) }
        assertEquals("tmux list-sessions no devolvió detalles.", error.detail)
    }

    @Test
    fun `list-sessions correcto descarta lineas invalidas`() {
        val sessions = TmuxOutputParser.parseListSessions("main|1|0|1700000000\nbasura\r\nlogs|2|1|1700000001\n", "", 0)
        assertEquals(listOf("main", "logs"), sessions.map { it.name })
    }

    @Test
    fun `list-windows ordena por indice y devuelve vacio si falla`() {
        val windows = TmuxOutputParser.parseListWindows("3|0|1|||zsh\n1|1|1|||vim\n", exitCode = 0)
        assertEquals(listOf(1, 3), windows.map { it.index })
        assertTrue(TmuxOutputParser.parseListWindows("1|1|1|||vim", exitCode = 1).isEmpty())
    }

    @Test
    fun `fallo de comando de gestion lleva el stderr o un mensaje por defecto`() {
        assertNull(TmuxOutputParser.managementFailure(0, "ignorado"))
        assertEquals("duplicate session: a", assertNotNull(TmuxOutputParser.managementFailure(1, "duplicate session: a\n")).detail)
        assertEquals("El servidor no devolvió detalles.", assertNotNull(TmuxOutputParser.managementFailure(1, " ")).detail)
    }
}
