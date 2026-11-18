package com.iaportafolio.argos.core.files

/**
 * Nombre seguro para escribir en una carpeta temporal propia un archivo leído del servidor y
 * entregarlo a un visor del sistema (hojas de cálculo), port de `QuickLookTempFile.safeName` de
 * `ArgosCore/Files/QuickLookTempFile.swift`. El nombre viene del servidor: nunca debe salir de esa
 * carpeta.
 */
object PreviewTempFileName {

    /** Nombre por defecto si no queda nada utilizable. */
    const val FALLBACK = "archivo"

    private const val MAX_LENGTH = 200
    private val FORBIDDEN = setOf('/'.code, '\\'.code, ':'.code)

    /**
     * Último componente, sin separadores ni caracteres de control, con su extensión (el visor
     * decide el tipo por ella). Nunca vacío ni «.»/«..».
     */
    fun safe(name: String): String {
        val last = name.trimEnd('/').substringAfterLast('/')
        val cleaned = buildString {
            last.codePoints().forEach { scalar ->
                if (scalar >= 0x20 && scalar != 0x7F && scalar !in FORBIDDEN) appendCodePoint(scalar)
            }
        }.trim(' ', '\t')
        val trimmed = cleaned.trimStart('.')
        if (trimmed.isEmpty()) return FALLBACK
        return trimmed.takeLastCodePoints(MAX_LENGTH)
    }

    /** Los últimos [count] puntos de código (sin partir un par sustituto). */
    private fun String.takeLastCodePoints(count: Int): String {
        val total = codePointCount(0, length)
        if (total <= count) return this
        return substring(offsetByCodePoints(0, total - count))
    }
}
