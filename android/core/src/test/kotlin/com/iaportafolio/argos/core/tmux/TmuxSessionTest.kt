package com.iaportafolio.argos.core.tmux

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/TmuxSessionTests.swift`. */
class TmuxSessionTest {

    @Test
    fun `linea bien formada parsea todos los campos`() {
        val session = assertNotNull(TmuxSession.parse("main|3|1|1700000000"))
        assertEquals("main", session.name)
        assertEquals(3, session.windowCount)
        assertTrue(session.isAttached)
        assertEquals(Instant.ofEpochSecond(1_700_000_000), session.createdAt)
    }

    @Test
    fun `attached 0 significa no adjunta`() {
        assertFalse(assertNotNull(TmuxSession.parse("logs|1|0|1700000000")).isAttached)
    }

    @Test
    fun `un nombre con barra vertical no hace desaparecer la sesion`() {
        val session = assertNotNull(TmuxSession.parse("api|v2|3|1|1700000000"))
        assertEquals("api|v2", session.name)
        assertEquals(3, session.windowCount)
        assertTrue(session.isAttached)
    }

    @ParameterizedTest
    @ValueSource(
        strings = [
            "", "   ", "main|3|1", "main|3|1|1700|extra", "main|x|1|1700000000",
            "main|3|y|1700000000", "main|3|1|notanepoch", "|3|1|1700000000",
        ],
    )
    fun `lineas invalidas devuelven null`(line: String) {
        assertNull(TmuxSession.parse(line))
    }

    @Test
    fun `espacios alrededor de la linea se toleran`() {
        val session = assertNotNull(TmuxSession.parse("  main|2|0|1700000000  \n"))
        assertEquals("main", session.name)
        assertEquals(2, session.windowCount)
    }

    @Test
    fun `el id es el nombre`() {
        assertEquals("a/b", assertNotNull(TmuxSession.parse("a/b|1|0|0")).id)
    }
}
