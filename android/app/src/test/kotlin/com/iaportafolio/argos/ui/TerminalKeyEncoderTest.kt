package com.iaportafolio.argos.ui

import com.iaportafolio.argos.ui.terminal.ExtraKey
import com.iaportafolio.argos.ui.terminal.ModifierLatch
import com.iaportafolio.argos.ui.terminal.StickyModifiers
import com.iaportafolio.argos.ui.terminal.TerminalKeyEncoder
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class TerminalKeyEncoderTest {

    private fun ByteArray.text() = String(this, Charsets.UTF_8)

    private fun key(key: ExtraKey, ctrl: Boolean = false, alt: Boolean = false, app: Boolean = false) =
        TerminalKeyEncoder.key(key, ctrl, alt, app).text()

    @ParameterizedTest
    @CsvSource("UP,A", "DOWN,B", "RIGHT,C", "LEFT,D", "HOME,H", "END,F")
    fun `flechas en modo normal y en modo cursor de aplicación`(name: String, final: Char) {
        val key = ExtraKey.valueOf(name)
        assertEquals("\u001B[$final", key(key))
        assertEquals("\u001BO$final", key(key, app = true))
    }

    @Test
    fun `flechas con modificadores usan el parámetro de xterm aunque haya modo aplicación`() {
        assertEquals("\u001B[1;5A", key(ExtraKey.UP, ctrl = true, app = true))
        assertEquals("\u001B[1;3D", key(ExtraKey.LEFT, alt = true))
        assertEquals("\u001B[1;7C", key(ExtraKey.RIGHT, ctrl = true, alt = true))
    }

    @Test
    fun `retroceder y avanzar página`() {
        assertEquals("\u001B[5~", key(ExtraKey.PAGE_UP))
        assertEquals("\u001B[6~", key(ExtraKey.PAGE_DOWN))
        assertEquals("\u001B[5;5~", key(ExtraKey.PAGE_UP, ctrl = true))
    }

    @Test
    fun `Esc, Tab, prefijo de tmux y símbolos`() {
        assertEquals("\u001B", key(ExtraKey.ESC))
        assertEquals("\u001B\u001B", key(ExtraKey.ESC, alt = true))
        assertEquals("\t", key(ExtraKey.TAB))
        assertContentEquals(byteArrayOf(0x02), TerminalKeyEncoder.key(ExtraKey.TMUX_PREFIX, ctrl = true, alt = true, cursorKeysApplicationMode = false))
        assertEquals("|", key(ExtraKey.PIPE))
        assertEquals("~", key(ExtraKey.TILDE))
        assertEquals("/", key(ExtraKey.SLASH))
        assertEquals("-", key(ExtraKey.DASH))
        assertEquals("\u001F", key(ExtraKey.SLASH, ctrl = true))
    }

    @Test
    fun `Ctrl y Alt solos no envían nada`() {
        assertEquals(0, TerminalKeyEncoder.key(ExtraKey.CTRL, ctrl = true, alt = false, cursorKeysApplicationMode = false).size)
        assertEquals(0, TerminalKeyEncoder.key(ExtraKey.ALT, ctrl = false, alt = true, cursorKeysApplicationMode = false).size)
    }

    @ParameterizedTest
    @CsvSource("a,1", "c,3", "z,26", "C,3", "' ',0", "@,0", "[,27", "\\,28", "],29", "^,30", "_,31", "?,127", "8,127")
    fun `Ctrl más tecla produce el código de control de xterm`(char: Char, expected: Int) {
        assertEquals(expected, TerminalKeyEncoder.controlCode(char.code))
        assertContentEquals(byteArrayOf(expected.toByte()), TerminalKeyEncoder.codePoint(char.code, ctrl = true, alt = false))
    }

    @Test
    fun `Ctrl no altera caracteres sin código de control`() {
        assertEquals("ñ".codePointAt(0), TerminalKeyEncoder.controlCode("ñ".codePointAt(0)))
    }

    @Test
    fun `Alt antepone ESC y se combina con Ctrl`() {
        assertEquals("\u001Bb", TerminalKeyEncoder.codePoint('b'.code, ctrl = false, alt = true).text())
        assertContentEquals(byteArrayOf(0x1B, 0x18), TerminalKeyEncoder.codePoint('x'.code, ctrl = true, alt = true))
    }

    @Test
    fun `texto del IME en UTF-8 con acentos, eñe y emoji y salto de línea como retorno`() {
        val encoded = TerminalKeyEncoder.text("añá😀\n", StickyModifiers())
        assertEquals("añá😀\r", encoded.bytes.text())
        assertEquals(StickyModifiers(), encoded.modifiers)
    }

    @Test
    fun `un surrogate suelto se sustituye por el carácter de reemplazo`() {
        assertEquals("a�", TerminalKeyEncoder.text("a\uD83D", StickyModifiers()).bytes.text())
    }

    @Test
    fun `Ctrl de un solo uso se aplica solo al primer carácter y se consume`() {
        val encoded = TerminalKeyEncoder.text("cd", StickyModifiers(ctrl = ModifierLatch.ONCE))
        assertContentEquals(byteArrayOf(0x03, 'd'.code.toByte()), encoded.bytes)
        assertEquals(StickyModifiers(), encoded.modifiers)
    }

    @Test
    fun `Ctrl fijado se aplica a todos los caracteres y sigue fijado`() {
        val locked = StickyModifiers(ctrl = ModifierLatch.LOCKED)
        val encoded = TerminalKeyEncoder.text("cd", locked)
        assertContentEquals(byteArrayOf(0x03, 0x04), encoded.bytes)
        assertEquals(locked, encoded.modifiers)
    }

    @Test
    fun `tocar Ctrl recorre apagado, un uso, fijado y apagado`() {
        val once = TerminalKeyEncoder.key(ExtraKey.CTRL, StickyModifiers(), cursorKeysApplicationMode = false)
        assertEquals(0, once.bytes.size)
        assertEquals(ModifierLatch.ONCE, once.modifiers.ctrl)
        val locked = once.modifiers.tap(ExtraKey.CTRL)
        assertEquals(ModifierLatch.LOCKED, locked.ctrl)
        assertEquals(ModifierLatch.OFF, locked.tap(ExtraKey.CTRL).ctrl)
        assertEquals(locked, locked.tap(ExtraKey.ESC))
    }

    @Test
    fun `una tecla de la fila con Alt de un solo uso lo consume`() {
        val encoded = TerminalKeyEncoder.key(ExtraKey.UP, StickyModifiers(alt = ModifierLatch.ONCE), cursorKeysApplicationMode = true)
        assertEquals("\u001B[1;3A", encoded.bytes.text())
        assertEquals(StickyModifiers(), encoded.modifiers)
    }
}
