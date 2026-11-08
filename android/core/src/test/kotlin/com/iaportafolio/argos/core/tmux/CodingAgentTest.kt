package com.iaportafolio.argos.core.tmux

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/CodingAgentTests.swift`. */
class CodingAgentTest {

    @ParameterizedTest
    @CsvSource("claude,CLAUDE", "codex,CODEX", "grok,GROK", "Claude,CLAUDE")
    fun `detecta por el proceso en primer plano`(command: String, expected: CodingAgent) {
        assertEquals(expected, CodingAgent.detect(command, windowName = "zsh"))
    }

    @Test
    fun `detecta por el nombre que Argos le puso a la ventana`() {
        assertEquals(CodingAgent.CODEX, CodingAgent.detect("node", windowName = "Codex"))
        assertEquals(CodingAgent.CLAUDE, CodingAgent.detect(null, windowName = "Claude Code"))
    }

    @Test
    fun `si la ventana volvio a su shell el nombre ya no cuenta`() {
        assertNull(CodingAgent.detect("zsh", windowName = "Claude Code"))
        assertNull(CodingAgent.detect("-bash", windowName = "Codex"))
    }

    @Test
    fun `un shell o un programa cualquiera no es un agente`() {
        assertNull(CodingAgent.detect("zsh", windowName = "zsh"))
        assertNull(CodingAgent.detect("vim", windowName = "claude-notes"))
    }

    @Test
    fun `solo cuentan las lineas marcadas con un binario conocido`() {
        val output = listOf(
            "Bienvenido a Ubuntu (MOTD)",
            "claude",
            "argos-agent:claude",
            "argos-agent:grok",
            "argos-agent:cursor",
            "  argos-agent:codex  ",
        ).joinToString("\n")
        assertEquals(setOf(CodingAgent.CLAUDE, CodingAgent.GROK, CodingAgent.CODEX), CodingAgent.parseInstalled(output))
    }

    @Test
    fun `salida vacia significa ninguno instalado`() {
        assertTrue(CodingAgent.parseInstalled("").isEmpty())
    }

    @Test
    fun `el script busca todos los binarios y termina con exito`() {
        val script = CodingAgent.installedAgentsScript
        CodingAgent.entries.forEach { assertTrue(it.binary in script) }
        assertTrue(CodingAgent.INSTALLED_MARKER in script)
        assertTrue(script.endsWith("exit 0"))
    }

    @Test
    fun `cada agente tiene una tecla de menu distinta`() {
        val keys = CodingAgent.entries.map { it.menuKey }
        assertEquals(keys.size, keys.toSet().size)
    }

    /** El script es sintácticamente válido para un `sh` POSIX real (se comprueba con `sh -n`). */
    @Test
    fun `el script es sh valido`() {
        val process = ProcessBuilder("/bin/sh", "-n", "-c", CodingAgent.installedAgentsScript)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText()
        assertEquals(0, process.waitFor(), output)
    }
}
