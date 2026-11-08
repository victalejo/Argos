package com.iaportafolio.argos.core.tmux

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/TmuxWindowTests.swift`. */
class TmuxWindowTest {

    @Test
    fun `linea bien formada parsea todos los campos`() {
        val w = assertNotNull(TmuxWindow.parse("2|1|3|blue|vim|editor"))
        assertEquals(2, w.index)
        assertEquals("editor", w.name)
        assertEquals("vim", w.currentCommand)
        assertTrue(w.isActive)
        assertEquals(3, w.paneCount)
        assertEquals(WindowColor.BLUE, w.color)
    }

    @Test
    fun `active 0 significa no activa`() {
        val w = assertNotNull(TmuxWindow.parse("0|0|1||bash|bash"))
        assertFalse(w.isActive)
        assertEquals(0, w.index)
    }

    @Test
    fun `sin color la opcion vacia da color null`() {
        assertNull(assertNotNull(TmuxWindow.parse("1|1|1||zsh|zsh")).color)
    }

    @Test
    fun `color desconocido se ignora sin invalidar la ventana`() {
        val w = assertNotNull(TmuxWindow.parse("1|1|1|chartreuse|zsh|zsh"))
        assertNull(w.color)
        assertEquals("zsh", w.name)
    }

    @Test
    fun `nombre con espacios se conserva`() {
        assertEquals("mi ventana", assertNotNull(TmuxWindow.parse("1|1|1||zsh|mi ventana")).name)
    }

    @Test
    fun `nombre con barra vertical se conserva porque va al final`() {
        val w = assertNotNull(TmuxWindow.parse("1|1|1|red|zsh|a|b"))
        assertEquals("a|b", w.name)
        assertEquals(WindowColor.RED, w.color)
    }

    @ParameterizedTest
    @ValueSource(strings = ["", "  ", "x|1|1|||bash", "1|1|1|||", "1|1|1||bash", "1|1|x|||bash", "1|x|1|||bash"])
    fun `lineas invalidas devuelven null`(line: String) {
        assertNull(TmuxWindow.parse(line))
    }

    @Test
    fun `comando vacio da currentCommand null`() {
        val w = assertNotNull(TmuxWindow.parse("1|1|1|||zsh"))
        assertNull(w.currentCommand)
        assertEquals("zsh", w.name)
    }
}
