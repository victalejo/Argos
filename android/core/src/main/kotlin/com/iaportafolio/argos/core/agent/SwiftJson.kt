package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode

/**
 * Escritor JSON que reproduce BYTE A BYTE la salida de Foundation (`JSONEncoder` con
 * `.sortedKeys` y `JSONSerialization`), porque lo que Android escribe al servidor o a la
 * stdin de `claude` debe ser idéntico a lo que escribe el Mac/iPhone.
 *
 * Reglas observadas (verificadas contra Swift 6.4, ver `swift-golden/` en los tests):
 * - Claves ordenadas lexicográficamente por UTF-16 (no numérico: `a10` < `a9`).
 * - Escapes: `"` `\\` `\b` `\f` `\n` `\r` `\t`, otros controles como `\u00xx` (hex en
 *   minúscula), y `/` como `\/` salvo con `.withoutEscapingSlashes`. El resto va en crudo.
 * - Formato «pretty»: sangría de 2 espacios, `"clave" : valor`; contenedor vacío como
 *   `{` + `\n\n` + sangría + `}`.
 * - Números: ver [Numbers].
 */
internal object SwiftJson {

    /** Cómo se escriben los números que no son enteros de 64 bits. */
    enum class Numbers {
        /**
         * `JSONEncoder` sobre un `JSONValue`: un número integral cabe en `Int` (se escribe
         * sin decimales); el resto usa la representación más corta de `Double.description`
         * (`0.21`, `1e-07`, `1e+20`).
         */
        SHORTEST,

        /** `JSONSerialization` (`NSNumber`): `%.17g` de C (`0.1` → `0.10000000000000001`). */
        PRINTF_17G,
    }

    fun compact(element: JsonElement, escapeSlashes: Boolean = true, numbers: Numbers = Numbers.SHORTEST): String =
        StringBuilder().also { write(it, element, Style(escapeSlashes, numbers, pretty = false), 0) }.toString()

    fun pretty(element: JsonElement, escapeSlashes: Boolean, numbers: Numbers): String =
        StringBuilder().also { write(it, element, Style(escapeSlashes, numbers, pretty = true), 0) }.toString()

    private data class Style(val escapeSlashes: Boolean, val numbers: Numbers, val pretty: Boolean)

    private fun write(out: StringBuilder, element: JsonElement, style: Style, level: Int) {
        when (element) {
            is JsonObject -> writeContainer(out, '{', '}', element.entries.sortedBy { it.key }, style, level) { entry ->
                writeString(out, entry.key, style.escapeSlashes)
                out.append(if (style.pretty) " : " else ":")
                write(out, entry.value, style, level + 1)
            }
            is JsonArray -> writeContainer(out, '[', ']', element, style, level) { write(out, it, style, level + 1) }
            is JsonNull -> out.append("null")
            is JsonPrimitive -> when {
                element.isString -> writeString(out, element.content, style.escapeSlashes)
                element.content == "true" || element.content == "false" -> out.append(element.content)
                else -> out.append(formatNumber(element.content, style.numbers))
            }
        }
    }

    private fun <T> writeContainer(
        out: StringBuilder,
        open: Char,
        close: Char,
        items: List<T>,
        style: Style,
        level: Int,
        writeItem: (T) -> Unit,
    ) {
        out.append(open)
        if (style.pretty) {
            out.append('\n')
            if (items.isEmpty()) out.append('\n')
            items.forEachIndexed { index, item ->
                if (index > 0) out.append(",\n")
                out.append(indent(level + 1))
                writeItem(item)
            }
            if (items.isNotEmpty()) out.append('\n')
            out.append(indent(level))
        } else {
            items.forEachIndexed { index, item ->
                if (index > 0) out.append(',')
                writeItem(item)
            }
        }
        out.append(close)
    }

    private fun indent(level: Int): String = "  ".repeat(level)

    private fun writeString(out: StringBuilder, value: String, escapeSlashes: Boolean) {
        out.append('"')
        for (c in value) {
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '/' && escapeSlashes -> out.append("\\/")
                c == '\b' -> out.append("\\b")
                c == '\u000C' -> out.append("\\f")
                c == '\n' -> out.append("\\n")
                c == '\r' -> out.append("\\r")
                c == '\t' -> out.append("\\t")
                c < ' ' -> out.append("\\u00").append(HEX[c.code shr 4]).append(HEX[c.code and 0xF])
                else -> out.append(c)
            }
        }
        out.append('"')
    }

    private const val HEX = "0123456789abcdef"

    /** Formatea el literal numérico [content] (tal cual llegó del JSON) como Foundation. */
    fun formatNumber(content: String, numbers: Numbers): String {
        content.toLongOrNull()?.let { return it.toString() }
        val value = content.toDoubleOrNull() ?: return content
        return when (numbers) {
            Numbers.SHORTEST -> integralLong(value)?.toString() ?: swiftDescription(value)
            Numbers.PRINTF_17G -> printf17g(value)
        }
    }

    private fun integralLong(value: Double): Long? =
        if (value == Math.rint(value) && value >= -9.223372036854775808E18 && value < 9.223372036854775808E18) {
            value.toLong()
        } else {
            null
        }

    /** `Double.description` de Swift: dígitos más cortos que reconstruyen el valor. */
    private fun swiftDescription(value: Double): String {
        val exact = BigDecimal(value)
        val shortest = (1..17).asSequence()
            .map { exact.round(MathContext(it, RoundingMode.HALF_EVEN)) }
            .first { it.toDouble() == value }
        return decimalOrExponent(shortest, exponentBelow = -4, exponentFrom = 16)
    }

    /** `%.17g` de C: 17 cifras significativas, sin ceros finales. */
    private fun printf17g(value: Double): String {
        if (value == 0.0) return if (1.0 / value < 0) "-0" else "0"
        val rounded = BigDecimal(value).round(MathContext(17, RoundingMode.HALF_EVEN))
        return decimalOrExponent(rounded, exponentBelow = -4, exponentFrom = 17)
    }

    private fun decimalOrExponent(number: BigDecimal, exponentBelow: Int, exponentFrom: Int): String {
        val stripped = number.stripTrailingZeros()
        val exponent = stripped.precision() - stripped.scale() - 1
        if (exponent in exponentBelow until exponentFrom) return stripped.toPlainString()
        val digits = stripped.unscaledValue().abs().toString()
        val mantissa = if (digits.length > 1) digits[0] + "." + digits.substring(1) else digits
        val sign = if (stripped.signum() < 0) "-" else ""
        val exponentSign = if (exponent < 0) "-" else "+"
        return sign + mantissa + "e" + exponentSign + Math.abs(exponent).toString().padStart(2, '0')
    }
}
