package com.iaportafolio.argos.ui.terminal

/** Teclas de la fila extra sobre el teclado (como la barra de SwiftTerm en iPhone o la de Termux). */
enum class ExtraKey(val repeats: Boolean = false) {
    ESC,
    TAB,
    CTRL,
    ALT,
    LEFT(repeats = true),
    UP(repeats = true),
    DOWN(repeats = true),
    RIGHT(repeats = true),
    PIPE,
    TILDE,
    SLASH,
    DASH,

    /** Prefijo de tmux (`Ctrl-b`). */
    TMUX_PREFIX,
    HOME,
    END,
    PAGE_UP(repeats = true),
    PAGE_DOWN(repeats = true),
}

/** Estado de un modificador pegajoso: apagado, para la próxima tecla o fijado. */
enum class ModifierLatch { OFF, ONCE, LOCKED }

/**
 * Ctrl y Alt pegajosos de la fila extra. Un toque los activa para la siguiente tecla, un
 * segundo toque los fija y un tercero los apaga. Inmutable: cada cambio devuelve una copia.
 */
data class StickyModifiers(
    val ctrl: ModifierLatch = ModifierLatch.OFF,
    val alt: ModifierLatch = ModifierLatch.OFF,
) {
    val ctrlActive: Boolean get() = ctrl != ModifierLatch.OFF
    val altActive: Boolean get() = alt != ModifierLatch.OFF

    /** Toque en la tecla del modificador ([ExtraKey.CTRL] o [ExtraKey.ALT]; el resto no cambia nada). */
    fun tap(key: ExtraKey): StickyModifiers = when (key) {
        ExtraKey.CTRL -> copy(ctrl = ctrl.next())
        ExtraKey.ALT -> copy(alt = alt.next())
        else -> this
    }

    /** Tras usarse en una tecla: los de un solo uso se apagan, los fijados siguen. */
    fun consumed(): StickyModifiers = StickyModifiers(ctrl = ctrl.afterUse(), alt = alt.afterUse())

    private fun ModifierLatch.next(): ModifierLatch = when (this) {
        ModifierLatch.OFF -> ModifierLatch.ONCE
        ModifierLatch.ONCE -> ModifierLatch.LOCKED
        ModifierLatch.LOCKED -> ModifierLatch.OFF
    }

    private fun ModifierLatch.afterUse(): ModifierLatch = if (this == ModifierLatch.ONCE) ModifierLatch.OFF else this
}

/** Bytes a enviar y modificadores que quedan tras enviarlos. */
class EncodedInput(val bytes: ByteArray, val modifiers: StickyModifiers)

/**
 * Traducción pura de teclas y texto a las secuencias que espera un terminal xterm
 * (`xterm-256color`, lo que pide el PTY): flechas `ESC [ A` (o `ESC O A` en modo cursor de
 * aplicación), modificadores xterm `ESC [ 1 ; m A`, Ctrl+letra → código de control y Alt →
 * prefijo ESC. Sin dependencias de Android: se prueba en la JVM.
 */
object TerminalKeyEncoder {
    private const val ESC = 0x1B
    private const val DEL = 0x7F
    private const val TMUX_PREFIX = 0x02
    private const val MAX_CODE_POINT = 0x10FFFF
    private const val REPLACEMENT_CHAR = 0xFFFD

    /** Secuencia de una tecla de la fila extra. Ctrl y Alt solos no envían nada. */
    fun key(key: ExtraKey, ctrl: Boolean, alt: Boolean, cursorKeysApplicationMode: Boolean): ByteArray = when (key) {
        ExtraKey.CTRL, ExtraKey.ALT -> ByteArray(0)
        ExtraKey.ESC -> withAlt(byteArrayOf(ESC.toByte()), alt)
        ExtraKey.TAB -> withAlt(byteArrayOf('\t'.code.toByte()), alt)
        ExtraKey.TMUX_PREFIX -> byteArrayOf(TMUX_PREFIX.toByte())
        ExtraKey.UP -> cursor('A', ctrl, alt, cursorKeysApplicationMode)
        ExtraKey.DOWN -> cursor('B', ctrl, alt, cursorKeysApplicationMode)
        ExtraKey.RIGHT -> cursor('C', ctrl, alt, cursorKeysApplicationMode)
        ExtraKey.LEFT -> cursor('D', ctrl, alt, cursorKeysApplicationMode)
        ExtraKey.HOME -> cursor('H', ctrl, alt, cursorKeysApplicationMode)
        ExtraKey.END -> cursor('F', ctrl, alt, cursorKeysApplicationMode)
        ExtraKey.PAGE_UP -> tilde(5, ctrl, alt)
        ExtraKey.PAGE_DOWN -> tilde(6, ctrl, alt)
        ExtraKey.PIPE -> codePoint('|'.code, ctrl, alt)
        ExtraKey.TILDE -> codePoint('~'.code, ctrl, alt)
        ExtraKey.SLASH -> codePoint('/'.code, ctrl, alt)
        ExtraKey.DASH -> codePoint('-'.code, ctrl, alt)
    }

    /** Tecla de la fila extra aplicando los modificadores pegajosos y consumiéndolos. */
    fun key(key: ExtraKey, modifiers: StickyModifiers, cursorKeysApplicationMode: Boolean): EncodedInput {
        if (key == ExtraKey.CTRL || key == ExtraKey.ALT) return EncodedInput(ByteArray(0), modifiers.tap(key))
        val bytes = key(key, modifiers.ctrlActive, modifiers.altActive, cursorKeysApplicationMode)
        return EncodedInput(bytes, modifiers.consumed())
    }

    /**
     * Un punto de código con modificadores: Ctrl lo convierte en código de control (tabla de
     * xterm/Termux) y Alt antepone ESC. Se codifica en UTF-8.
     */
    fun codePoint(codePoint: Int, ctrl: Boolean, alt: Boolean): ByteArray {
        val value = if (ctrl) controlCode(codePoint) else codePoint
        return withAlt(utf8(value), alt)
    }

    /**
     * Texto del teclado del sistema (IME): `\n` se envía como `\r` (Intro de un terminal). Si
     * hay modificadores pegajosos se aplican al primer carácter cuando son de un solo uso, o a
     * todos cuando están fijados.
     */
    fun text(text: CharSequence, modifiers: StickyModifiers): EncodedInput {
        var mods = modifiers
        val out = java.io.ByteArrayOutputStream(text.length)
        codePoints(text).forEach { raw ->
            val cp = if (raw == '\n'.code) '\r'.code else raw
            out.write(codePoint(cp, mods.ctrlActive, mods.altActive))
            mods = mods.consumed()
        }
        return EncodedInput(out.toByteArray(), mods)
    }

    /** Código de control de Ctrl+[codePoint] (misma tabla que Termux/xterm). */
    fun controlCode(codePoint: Int): Int = when (codePoint) {
        in 'a'.code..'z'.code -> codePoint - 'a'.code + 1
        in 'A'.code..'Z'.code -> codePoint - 'A'.code + 1
        ' '.code, '2'.code, '@'.code -> 0
        '['.code, '3'.code -> ESC
        '\\'.code, '4'.code -> 28
        ']'.code, '5'.code -> 29
        '^'.code, '6'.code -> 30
        '_'.code, '7'.code, '/'.code, '-'.code -> 31
        '8'.code, '?'.code -> DEL
        else -> codePoint
    }

    private fun cursor(final: Char, ctrl: Boolean, alt: Boolean, applicationMode: Boolean): ByteArray {
        val mod = modifierParameter(ctrl, alt)
        val sequence = when {
            mod > 1 -> "\u001B[1;$mod$final"
            applicationMode -> "\u001BO$final"
            else -> "\u001B[$final"
        }
        return sequence.toByteArray(Charsets.US_ASCII)
    }

    private fun tilde(number: Int, ctrl: Boolean, alt: Boolean): ByteArray {
        val mod = modifierParameter(ctrl, alt)
        val sequence = if (mod > 1) "\u001B[$number;$mod~" else "\u001B[$number~"
        return sequence.toByteArray(Charsets.US_ASCII)
    }

    /** Parámetro de modificadores de xterm: 1 + Alt(2) + Ctrl(4). */
    private fun modifierParameter(ctrl: Boolean, alt: Boolean): Int = 1 + (if (alt) 2 else 0) + (if (ctrl) 4 else 0)

    private fun withAlt(bytes: ByteArray, alt: Boolean): ByteArray = if (alt) byteArrayOf(ESC.toByte()) + bytes else bytes

    private fun utf8(codePoint: Int): ByteArray {
        val valid = codePoint in 0..MAX_CODE_POINT && codePoint !in Character.MIN_SURROGATE.code..Character.MAX_SURROGATE.code
        return String(Character.toChars(if (valid) codePoint else REPLACEMENT_CHAR)).toByteArray(Charsets.UTF_8)
    }

    /** Puntos de código de [text]; un surrogate suelto se cambia por U+FFFD. */
    private fun codePoints(text: CharSequence): List<Int> {
        val result = ArrayList<Int>(text.length)
        var index = 0
        while (index < text.length) {
            val char = text[index]
            if (Character.isHighSurrogate(char) && index + 1 < text.length && Character.isLowSurrogate(text[index + 1])) {
                result += Character.toCodePoint(char, text[index + 1])
                index += 2
            } else {
                result += if (Character.isSurrogate(char)) REPLACEMENT_CHAR else char.code
                index++
            }
        }
        return result
    }
}
