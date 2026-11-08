package com.iaportafolio.argos.core

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/ShellQuotingTests.swift`, más una prueba real contra `/bin/sh`. */
class ShellQuotingTest {

    private val esc = "'\\''" // secuencia POSIX que representa UNA comilla simple

    @Test
    fun `texto simple se envuelve en comillas simples`() {
        assertEquals("'main'", ShellQuoting.singleQuoted("main"))
    }

    @Test
    fun `cadena vacia produce comillas vacias`() {
        assertEquals("''", ShellQuoting.singleQuoted(""))
    }

    @Test
    fun `una comilla simple interna se escapa`() {
        assertEquals("'a${esc}b'", ShellQuoting.singleQuoted("a'b"))
    }

    @Test
    fun `cada comilla simple se escapa independientemente`() {
        assertEquals("'$esc$esc'", ShellQuoting.singleQuoted("''"))
    }

    @ParameterizedTest
    @ValueSource(strings = ["a b", "a;rm -rf /", "a&&b", "a|b", "\$(whoami)", "`id`", "a\$VAR", "a\nb", "a\\b"])
    fun `metacaracteres quedan literales`(input: String) {
        val quoted = ShellQuoting.singleQuoted(input)
        assertTrue(quoted.startsWith("'") && quoted.endsWith("'"))
        assertEquals("'$input'", quoted)
    }

    /** El shell real debe devolver exactamente la entrada: ninguna expansión ni inyección. */
    @ParameterizedTest
    @ValueSource(strings = ["a'b", "''", "\$(whoami)", "`id`", "a;echo PWNED", "x\ny", "'; echo PWNED; '"])
    fun `el shell real recibe el literal intacto`(input: String) {
        val process = ProcessBuilder("/bin/sh", "-c", "printf %s " + ShellQuoting.singleQuoted(input))
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText()
        assertEquals(0, process.waitFor())
        assertEquals(input, output)
    }
}
