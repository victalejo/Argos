package com.iaportafolio.argos.core.monitor

import java.util.Locale
import kotlin.math.roundToInt

/** Formato legible (en español) de tamaños y duraciones. */
object ResourceFormat {

    private val locale: Locale = Locale.forLanguageTag("es-ES")
    private val units = listOf("KB", "MB", "GB", "TB")
    private const val STEP = 1024.0
    private const val SECONDS_PER_DAY = 86_400L
    private const val SECONDS_PER_HOUR = 3_600L
    private const val SECONDS_PER_MINUTE = 60L

    fun kilobytes(kb: Long): String {
        var value = kb.toDouble()
        var unit = 0
        while (value >= STEP && unit < units.size - 1) {
            value /= STEP
            unit += 1
        }
        if (unit == 0) return "$kb KB"
        return String.format(locale, "%.1f %s", value, units[unit])
    }

    fun uptime(seconds: Long): String {
        val days = seconds / SECONDS_PER_DAY
        val hours = (seconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR
        val minutes = (seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE
        return when {
            days > 0 -> "$days d $hours h"
            hours > 0 -> "$hours h $minutes min"
            minutes > 0 -> "$minutes min"
            else -> "$seconds s"
        }
    }

    fun percent(fraction: Double): String = "${(fraction * 100).roundToInt()} %"
}
