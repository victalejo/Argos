package com.iaportafolio.argos.core.usage

import com.iaportafolio.argos.core.agent.SwiftText
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/*
 * Límites de uso de la suscripción de Claude (ventana de 5 h, semanal…) tal como los ve Claude
 * Code (lógica pura; port de `ArgosCore/ClaudeUsage/ClaudeLimits.swift`). Claude Code pasa a su
 * statusline un JSON con `rate_limits: {five_hour: {used_percentage, resets_at}, seven_day: {…}}`;
 * la statusline de Argos ([ClaudeLimitsInstaller]) lo guarda en el servidor y el sondeo lo lee.
 *
 * Formato del archivo (`~/.config/argos/claude-limits.json`): primera línea, la hora del servidor
 * (epoch) en que se guardó; el resto, el JSON de la statusline tal cual.
 */

/** Una ventana de límite («5 h», «semana»…). [resetsAt] va en el reloj de ESTE dispositivo. */
data class ClaudeLimitWindow(
    /** Clave del servidor de Anthropic (`five_hour`, `seven_day`, `seven_day_opus`…). */
    val kind: String,
    /** Porcentaje usado (0…100) cuando se leyó. */
    val usedPercent: Double,
    /** Cuándo se reinicia (`null` si no lo dice). */
    val resetsAt: Instant?,
) {
    /** Porcentaje que vale ahora: una ventana ya reiniciada vuelve a 0. */
    fun effectivePercent(now: Instant): Double {
        if (resetsAt != null && !resetsAt.isAfter(now)) return 0.0
        return usedPercent.coerceIn(0.0, 100.0)
    }

    /** Porcentaje entero que se enseña (redondeado como Swift). */
    fun displayPercent(now: Instant): Int = effectivePercent(now).roundToInt()

    /** Nombre de la ventana; la app lo traduce con sus cadenas. */
    val label: ClaudeLimitLabel
        get() = when {
            kind == FIVE_HOUR -> ClaudeLimitLabel.FiveHour
            kind == SEVEN_DAY -> ClaudeLimitLabel.SevenDay
            kind.startsWith("${SEVEN_DAY}_") -> ClaudeLimitLabel.SevenDayScoped(capitalized(kind.drop(SEVEN_DAY.length + 1)))
            else -> ClaudeLimitLabel.Other(capitalized(kind))
        }

    /** Orden: 5 h, semana y luego el resto por nombre. */
    internal val sortRank: Int
        get() = when (kind) {
            FIVE_HOUR -> 0
            SEVEN_DAY -> 1
            else -> 2
        }

    companion object {
        const val FIVE_HOUR = "five_hour"
        const val SEVEN_DAY = "seven_day"

        /** `seven_day_opus` -> «Opus»: guiones bajos a espacios y cada palabra en mayúscula (como `capitalized`). */
        internal fun capitalized(key: String): String =
            key.replace('_', ' ').split(' ').joinToString(" ") { word ->
                word.lowercase().replaceFirstChar { it.titlecase() }
            }
    }
}

/** Nombre de una ventana, sin texto: la app elige la cadena. */
sealed interface ClaudeLimitLabel {
    data object FiveHour : ClaudeLimitLabel
    data object SevenDay : ClaudeLimitLabel

    /** «Semana (Opus)». */
    data class SevenDayScoped(val scope: String) : ClaudeLimitLabel

    /** Una clave que Argos no conoce, legible. */
    data class Other(val name: String) : ClaudeLimitLabel
}

/**
 * Lectura de límites de un servidor. [capturedAt]: cuándo los guardó la statusline (reloj local).
 * Créala con [of], que ordena las ventanas (5 h, semana y el resto por nombre) como el `init` de Swift.
 */
data class ClaudeLimitsReading(val windows: List<ClaudeLimitWindow>, val capturedAt: Instant) {

    companion object {
        /** Lectura con las ventanas ordenadas: 5 h, semana y el resto por nombre. */
        fun of(windows: List<ClaudeLimitWindow>, capturedAt: Instant): ClaudeLimitsReading =
            ClaudeLimitsReading(windows.sortedWith(compareBy<ClaudeLimitWindow>({ it.sortRank }, { it.kind })), capturedAt)

        /**
         * Interpreta la salida de [ClaudeLimitsInstaller.POLL_COMMAND]: `now <epoch del servidor>` y,
         * si existe, el archivo (`<epoch>` + JSON). Las horas del servidor se pasan al reloj local con
         * la diferencia entre `now` y [localNow]. `null` si no hay archivo o no trae límites.
         */
        fun parse(lines: List<String>, localNow: Instant = Instant.now()): ClaudeLimitsReading? {
            val nowIndex = lines.indexOfFirst { it.startsWith("now ") }
            if (nowIndex < 0) return null
            val serverNow = SwiftText.trimWhitespace(lines[nowIndex].drop(4)).toDoubleOrNull() ?: return null
            val rest = lines.drop(nowIndex + 1)
            val captured = rest.firstOrNull()?.let { SwiftText.trimWhitespace(it).toDoubleOrNull() } ?: return null
            val json = rest.drop(1).joinToString("\n")
            val offset = epochSeconds(localNow) - serverNow
            val windows = windows(json, offset)?.takeIf { it.isNotEmpty() } ?: return null
            return of(windows, instant(captured + offset))
        }

        /** Igual que [parse] con la salida entera del comando (las líneas vacías no cuentan). */
        fun parse(output: String, localNow: Instant = Instant.now()): ClaudeLimitsReading? =
            parse(SwiftText.lines(output), localNow)

        /**
         * Ventanas de `rate_limits` del JSON de la statusline. [clockOffset] (s) se suma a las horas
         * del servidor. `null` si el JSON no es válido o no trae `rate_limits`.
         */
        fun windows(statusLineJson: String, clockOffset: Double = 0.0): List<ClaudeLimitWindow>? {
            val root = runCatching { Json.parseToJsonElement(statusLineJson) }.getOrNull() as? JsonObject ?: return null
            val limits = root["rate_limits"] as? JsonObject ?: return null
            return limits.mapNotNull { (kind, value) ->
                val row = value as? JsonObject ?: return@mapNotNull null
                val used = (row["used_percentage"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
                    ?: return@mapNotNull null
                val resets = resetInstant(row["resets_at"] as? JsonPrimitive)?.plusMillis((clockOffset * 1000).roundToLong())
                ClaudeLimitWindow(kind, used, resets)
            }
        }

        /** `resets_at` llega en segundos epoch; por si acaso, también ISO 8601. */
        private fun resetInstant(value: JsonPrimitive?): Instant? {
            if (value == null) return null
            if (value.isString) {
                return runCatching { OffsetDateTime.parse(value.content).toInstant() }.getOrNull()
            }
            val seconds = value.doubleOrNull ?: return null
            // Milisegundos por error: más allá del año 5000 en segundos.
            return instant(if (seconds > MILLIS_THRESHOLD) seconds / 1000 else seconds)
        }

        private const val MILLIS_THRESHOLD = 100_000_000_000.0

        internal fun epochSeconds(instant: Instant): Double = instant.toEpochMilli() / 1000.0

        internal fun instant(epochSeconds: Double): Instant = Instant.ofEpochMilli((epochSeconds * 1000).roundToLong())
    }
}

/** Nivel del aviso, de menos a más grave (el orden importa: se comparan). */
enum class ClaudeLimitsLevel { NORMAL, HIGH, CRITICAL }

/** Estado de los límites de un servidor tal como lo enseña la app. */
data class ClaudeLimitsStatus(
    val reading: ClaudeLimitsReading,
    /** La ventana más llena (la que manda en el aviso). */
    val worst: ClaudeLimitWindow,
    val worstPercent: Int,
    val level: ClaudeLimitsLevel,
) {
    companion object {
        /** Desde aquí se avisa («vas al 85 %»). */
        const val HIGH_FROM = 85

        /** Desde aquí, el aviso es urgente. */
        const val CRITICAL_FROM = 95

        fun evaluate(reading: ClaudeLimitsReading, now: Instant = Instant.now()): ClaudeLimitsStatus? {
            // Como `max(by:)` de Swift: con empate gana la primera (las ventanas van ordenadas).
            var best: Pair<ClaudeLimitWindow, Int>? = null
            for (window in reading.windows) {
                val percent = window.displayPercent(now)
                if (best == null || percent > best.second) best = window to percent
            }
            val (worst, percent) = best ?: return null
            return ClaudeLimitsStatus(reading, worst, percent, levelOf(percent))
        }

        fun levelOf(percent: Int): ClaudeLimitsLevel = when {
            percent >= CRITICAL_FROM -> ClaudeLimitsLevel.CRITICAL
            percent >= HIGH_FROM -> ClaudeLimitsLevel.HIGH
            else -> ClaudeLimitsLevel.NORMAL
        }
    }
}

/** Qué día cae un reinicio respecto a ahora (la app pone «a las…», «mañana a las…» o «el lun…»). */
enum class ClaudeLimitResetDay { TODAY, TOMORROW, LATER }

object ClaudeLimitReset {
    fun day(reset: Instant, now: Instant, zone: ZoneId = ZoneId.systemDefault()): ClaudeLimitResetDay {
        val resetDate = ZonedDateTime.ofInstant(reset, zone).toLocalDate()
        val today = ZonedDateTime.ofInstant(now, zone).toLocalDate()
        return when (resetDate) {
            today -> ClaudeLimitResetDay.TODAY
            today.plus(1, ChronoUnit.DAYS) -> ClaudeLimitResetDay.TOMORROW
            else -> ClaudeLimitResetDay.LATER
        }
    }
}

/** Paso de una ventana a «alto» o «crítico» (para avisar una sola vez por ventana y nivel). */
data class ClaudeLimitAlert(val status: ClaudeLimitsStatus) {

    /** Identificador estable: misma ventana, mismo reinicio y mismo nivel = mismo aviso. */
    val key: String
        get() {
            val reset = status.worst.resetsAt
                ?.let { (ClaudeLimitsReading.epochSeconds(it) / SAME_RESET_TOLERANCE_SECONDS).roundToLong().toString() } ?: "-"
            return "${status.worst.kind}-$reset-${status.level.ordinal}"
        }

    companion object {
        /**
         * Margen para considerar «el mismo reinicio»: la hora pasa del reloj del servidor al local con
         * una diferencia que baila unos segundos entre vueltas.
         */
        const val SAME_RESET_TOLERANCE_SECONDS = 300.0

        /** Aviso nuevo al pasar de [previous] a [current] (solo al SUBIR de nivel, o con una ventana nueva ya alta). */
        fun transition(previous: ClaudeLimitsStatus?, current: ClaudeLimitsStatus?): ClaudeLimitAlert? {
            if (current == null || current.level == ClaudeLimitsLevel.NORMAL) return null
            if (previous != null && previous.level >= current.level && previous.worst.kind == current.worst.kind &&
                sameReset(previous.worst.resetsAt, current.worst.resetsAt)
            ) {
                return null
            }
            return ClaudeLimitAlert(current)
        }

        private fun sameReset(lhs: Instant?, rhs: Instant?): Boolean = when {
            lhs == null && rhs == null -> true
            lhs != null && rhs != null ->
                abs(ClaudeLimitsReading.epochSeconds(lhs) - ClaudeLimitsReading.epochSeconds(rhs)) < SAME_RESET_TOLERANCE_SECONDS
            else -> false
        }
    }
}
