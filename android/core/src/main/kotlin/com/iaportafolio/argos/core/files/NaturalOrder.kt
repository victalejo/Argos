package com.iaportafolio.argos.core.files

import java.math.BigInteger
import java.text.Collator
import java.util.Locale

/**
 * Orden natural de nombres, equivalente práctico de `localizedStandardCompare` (Finder):
 * sin distinguir mayúsculas, con los tramos de dígitos comparados como números
 * ("file2" < "file10") y un desempate determinista si todo lo demás es igual.
 */
internal object NaturalOrder : Comparator<String> {

    private val collator: Collator = Collator.getInstance(Locale.ROOT).apply {
        strength = Collator.SECONDARY // ignora mayúsculas, respeta acentos
    }

    private val chunkPattern = Regex("\\d+|\\D+")

    override fun compare(a: String, b: String): Int {
        val left = chunkPattern.findAll(a).map { it.value }.toList()
        val right = chunkPattern.findAll(b).map { it.value }.toList()
        for (i in 0 until minOf(left.size, right.size)) {
            val result = compareChunks(left[i], right[i])
            if (result != 0) return result
        }
        if (left.size != right.size) return left.size.compareTo(right.size)
        return a.compareTo(b) // orden forzado: nunca "iguales" si difieren
    }

    private fun compareChunks(x: String, y: String): Int {
        val xDigits = x[0].isDigit()
        val yDigits = y[0].isDigit()
        return when {
            xDigits && yDigits -> BigInteger(x).compareTo(BigInteger(y))
            else -> collator.compare(x, y)
        }
    }
}
