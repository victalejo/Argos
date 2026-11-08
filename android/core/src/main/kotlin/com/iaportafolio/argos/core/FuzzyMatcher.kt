package com.iaportafolio.argos.core

import java.text.Normalizer
import java.util.Locale

/**
 * Coincidencia difusa para el selector rápido y el filtro de archivos
 * (port de `ArgosCore/FuzzyMatcher.swift`).
 */
object FuzzyMatcher {
    private const val CONTIGUOUS_BONUS = 5
    private const val WORD_START_BONUS = 3
    private const val MATCH_POINT = 1
    private val WORD_SEPARATORS = setOf(' ', '/', '-')
    private val COMBINING_MARKS = Regex("\\p{Mn}+")

    /**
     * Puntuación (mayor = mejor) si [query] hace subsequence-match en [text] (sin distinguir
     * mayúsculas ni acentos), o `null` si no coincide. Una query vacía siempre coincide (0).
     */
    fun score(query: String, text: String): Int? {
        val q = normalize(query)
        if (q.isEmpty()) return 0
        val t = normalize(text)
        if (t.isEmpty()) return null

        var score = 0
        var from = 0
        var lastMatch = -2
        for (qc in q) {
            val found = t.indexOf(qc, startIndex = from)
            if (found < 0) return null
            if (found == lastMatch + 1) score += CONTIGUOUS_BONUS
            if (found == 0 || t[found - 1] in WORD_SEPARATORS) score += WORD_START_BONUS
            score += MATCH_POINT
            lastMatch = found
            from = found + 1
        }
        return score
    }

    /** Quita diacríticos (NFD + marcas combinantes) y pasa a minúsculas. */
    private fun normalize(s: String): String =
        COMBINING_MARKS.replace(Normalizer.normalize(s, Normalizer.Form.NFD), "").lowercase(Locale.ROOT)
}
