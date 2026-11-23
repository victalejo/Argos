package com.iaportafolio.argos.core.monitor

import kotlin.math.roundToInt

/**
 * Memoria del servidor para el aviso «se está quedando sin memoria» (port de
 * `ArgosCore/Monitor/ServerMemoryPressure.swift`). Cuenta RAM y swap juntas: con swap, el kernel
 * no mata procesos hasta llenar las dos. [claudeProcesses] = procesos `claude` del usuario
 * (`null` si la línea no llegó).
 */
data class ServerMemoryReading(
    val totalKB: Long,
    val availableKB: Long,
    val swapTotalKB: Long,
    val swapFreeKB: Long,
    val claudeProcesses: Int? = null,
) {
    /** Fracción libre (RAM disponible + swap libre) entre 0 y 1; 1 si no hay nada que medir. */
    val freeFraction: Double
        get() {
            val total = totalKB + swapTotalKB
            if (total <= 0) return 1.0
            return ((availableKB + swapFreeKB).toDouble() / total).coerceIn(0.0, 1.0)
        }

    /** Porcentaje usado (0…100) redondeado. */
    val usedPercent: Int get() = ((1.0 - freeFraction) * 100).roundToInt()

    companion object {
        /**
         * Lee la salida de [ServerMemoryPressure.COMMAND]: `mem <total> <disponible> <swapTotal>
         * <swapLibre>` (solo Linux) y `claude <n>` opcional. Sin línea `mem` válida (otro sistema,
         * salida rara o total 0) devuelve `null`: sin lectura no hay aviso.
         */
        fun parse(output: String): ServerMemoryReading? {
            val lines = output.lines().map { it.trim().split(WHITESPACE).filter(String::isNotEmpty) }
            val mem = lines.firstOrNull { it.firstOrNull() == "mem" } ?: return null
            if (mem.size != MEM_FIELDS + 1) return null
            val values = mem.drop(1).map { it.toLongOrNull() ?: return null }
            if (values.any { it < 0 } || values[0] <= 0) return null
            val claude = lines.firstOrNull { it.firstOrNull() == "claude" }
                ?.takeIf { it.size == 2 }
                ?.get(1)?.toIntOrNull()
                ?.takeIf { it >= 0 }
            return ServerMemoryReading(values[0], values[1], values[2], values[3], claude)
        }

        private const val MEM_FIELDS = 4
        private val WHITESPACE = Regex("\\s+")
    }
}

/** Nivel del aviso, de menos a más grave (el orden importa: se comparan). */
enum class ServerMemoryPressureLevel { NORMAL, HIGH, CRITICAL }

/** Lo que muestra el aviso: nivel, porcentaje usado y procesos de Claude (`null` o 0 = no se citan). */
data class ServerMemoryWarning(val level: ServerMemoryPressureLevel, val usedPercent: Int, val claudeProcesses: Int?) {
    /** Antes de arrancar otra sesión con el servidor casi lleno se pide confirmación. */
    val needsConfirmationToStart: Boolean get() = ServerMemoryPressure.needsConfirmationToStart(level)

    /** Procesos de Claude que se citan en el mensaje (`null` = ninguno o desconocido). */
    val citedClaudeProcesses: Int? get() = claudeProcesses?.takeIf { it > 0 }
}

/** Umbrales y comando del aviso de memoria (idénticos a los de Swift). */
object ServerMemoryPressure {
    /** Por debajo de esta fracción libre: crítico. */
    const val CRITICAL_BELOW = 0.10

    /** Por debajo de esta fracción libre: alto. */
    const val HIGH_BELOW = 0.20

    /** Histéresis: un aviso ya mostrado no se retira hasta superar esta fracción libre. */
    const val CLEAR_ABOVE = 0.25

    /** Una sola lectura: memoria de `/proc/meminfo` y número de procesos `claude` del usuario. POSIX sh. */
    const val COMMAND: String =
        "awk '/^MemTotal:/{t=\$2} /^MemAvailable:/{a=\$2} /^SwapTotal:/{st=\$2} /^SwapFree:/{sf=\$2} " +
            "END{if(t>0) print \"mem\", t, a+0, st+0, sf+0}' /proc/meminfo 2>/dev/null; " +
            "printf 'claude %s\\n' \"\$(pgrep -x -u \"\$(id -u)\" claude 2>/dev/null | wc -l | tr -d ' ')\""

    /** Nivel de [reading] sabiendo el anterior ([previous]) para no parpadear cerca del umbral. */
    fun evaluate(reading: ServerMemoryReading?, previous: ServerMemoryPressureLevel? = null): ServerMemoryPressureLevel {
        val free = reading?.freeFraction ?: return ServerMemoryPressureLevel.NORMAL
        return when {
            free < CRITICAL_BELOW -> ServerMemoryPressureLevel.CRITICAL
            free < HIGH_BELOW -> ServerMemoryPressureLevel.HIGH
            previous != null && previous > ServerMemoryPressureLevel.NORMAL && free < CLEAR_ABOVE -> ServerMemoryPressureLevel.HIGH
            else -> ServerMemoryPressureLevel.NORMAL
        }
    }

    fun needsConfirmationToStart(level: ServerMemoryPressureLevel): Boolean = level == ServerMemoryPressureLevel.CRITICAL

    /** Aviso que mostrar (`null` en nivel normal o sin lectura). */
    fun warning(reading: ServerMemoryReading?, level: ServerMemoryPressureLevel): ServerMemoryWarning? {
        if (reading == null || level == ServerMemoryPressureLevel.NORMAL) return null
        return ServerMemoryWarning(level, reading.usedPercent, reading.claudeProcesses)
    }
}

/** Lectura de la memoria del servidor. Aparte de `SSHServicing` para no obligar a los dobles. */
interface ServerMemoryReader {
    /** `null` si el servidor no da la memoria (no Linux). */
    suspend fun serverMemory(): ServerMemoryReading?
}
