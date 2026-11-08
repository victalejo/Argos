package com.iaportafolio.argos.core.agent

import java.util.Base64

/**
 * Utilidades de texto que reproducen la semántica de Foundation/Swift que usa el núcleo
 * de Apple, para que Android parsee las MISMAS salidas del servidor de la misma forma.
 */
internal object SwiftText {

    /** Separadores de `Character.isNewline` de Swift (`\r\n` cuenta como uno solo). */
    private val newlineSeparators = Regex("\r\n|[\n\u000B\u000C\r\u0085\u2028\u2029]")

    /** `split(whereSeparator: \.isNewline)`: parte en líneas y omite las vacías. */
    fun lines(text: String): List<String> = text.split(newlineSeparators).filter { it.isNotEmpty() }

    /** `CharacterSet.whitespaces`: tabulador + categoría Unicode Zs. */
    fun isWhitespace(c: Char): Boolean = c == '\t' || Character.getType(c) == Character.SPACE_SEPARATOR.toInt()

    /**
     * `CharacterSet.whitespacesAndNewlines` (y la propiedad Unicode `White_Space` que usa
     * `Character.isWhitespace`): espacios Zs, tab, U+000A–U+000D, U+0085, U+2028 y U+2029.
     */
    fun isWhitespaceOrNewline(c: Char): Boolean =
        isWhitespace(c) || c in '\n'..'\r' || c == '\u0085' || c == '\u2028' || c == '\u2029'

    /** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
    fun trimWhitespaceAndNewlines(text: String): String = text.trim(::isWhitespaceOrNewline)

    /** `trimmingCharacters(in: .whitespaces)`. */
    fun trimWhitespace(text: String): String = text.trim(::isWhitespace)

    /**
     * `Data(base64Encoded:)`: base64 estándar ESTRICTO (longitud múltiplo de 4, sin
     * caracteres ajenos). Devuelve `null` si no es válido.
     */
    fun decodeBase64(text: String): ByteArray? {
        if (text.length % 4 != 0) return null
        return runCatching { Base64.getDecoder().decode(text) }.getOrNull()
    }

    /** `Data.base64EncodedString()`: base64 estándar con relleno y sin saltos de línea. */
    fun encodeBase64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    /**
     * `String.prefix(n)` de Swift: los primeros [count] caracteres VISIBLES (clusters de
     * grafemas), sin partir emojis compuestos ni letras con diacríticos combinados.
     *
     * Aproximación determinista de los clusters extendidos de Unicode (igual en la JVM y en
     * Android): un carácter base absorbe marcas combinantes, selectores de variación,
     * modificadores de tono de piel, etiquetas, secuencias ZWJ y pares de banderas.
     */
    fun graphemePrefix(text: String, count: Int): String {
        var index = 0
        var clusters = 0
        while (index < text.length && clusters < count) {
            index = nextClusterEnd(text, index)
            clusters++
        }
        return text.substring(0, index)
    }

    private fun nextClusterEnd(text: String, start: Int): Int {
        val first = text.codePointAt(start)
        var index = start + Character.charCount(first)
        if (first == '\r'.code && index < text.length && text[index] == '\n') return index + 1
        if (isRegionalIndicator(first) && index < text.length) {
            val second = text.codePointAt(index)
            if (isRegionalIndicator(second)) return index + Character.charCount(second)
        }
        while (index < text.length) {
            val next = text.codePointAt(index)
            index = when {
                next == ZERO_WIDTH_JOINER -> {
                    val afterJoiner = index + Character.charCount(next)
                    if (afterJoiner < text.length) {
                        afterJoiner + Character.charCount(text.codePointAt(afterJoiner))
                    } else {
                        afterJoiner
                    }
                }
                isExtending(next) -> index + Character.charCount(next)
                else -> return index
            }
        }
        return index
    }

    private const val ZERO_WIDTH_JOINER = 0x200D

    private fun isRegionalIndicator(codePoint: Int): Boolean = codePoint in 0x1F1E6..0x1F1FF

    private fun isExtending(codePoint: Int): Boolean {
        val type = Character.getType(codePoint)
        return type == Character.NON_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt() ||
            type == Character.COMBINING_SPACING_MARK.toInt() ||
            codePoint in 0xFE00..0xFE0F ||
            codePoint in 0xE0100..0xE01EF ||
            codePoint in 0x1F3FB..0x1F3FF ||
            codePoint in 0xE0020..0xE007F
    }
}
