package com.iaportafolio.argos.core.monitor

/**
 * Contadores acumulados de CPU (`/proc/stat`). El % de uso se obtiene comparando dos
 * muestras, porque los contadores son acumulados desde el arranque.
 */
data class CpuTicks(val total: Long, val idle: Long) {
    /**
     * Fracción de CPU ocupada (0…1) entre [previous] y esta muestra, o `null` si no hay
     * avance (misma muestra o contadores reiniciados).
     */
    fun usageSince(previous: CpuTicks): Double? {
        val totalDelta = total - previous.total
        val idleDelta = idle - previous.idle
        if (totalDelta <= 0 || idleDelta < 0) return null
        return 1 - idleDelta.toDouble() / totalDelta.toDouble()
    }
}

/** Capacidad usada / total en KB (memoria, swap o disco). */
data class ResourceUsage(val usedKB: Long, val totalKB: Long) {
    val fraction: Double
        get() = if (totalKB > 0) (usedKB.toDouble() / totalKB.toDouble()).coerceIn(0.0, 1.0) else 0.0
}

/** Proceso de la lista de los que más CPU consumen. */
data class ResourceProcess(
    val pid: Int,
    /** `%CPU` de `ps` (promedio de vida del proceso; puede superar 100 con varios núcleos). */
    val cpuPercent: Double,
    val memPercent: Double,
    val command: String,
) {
    val id: Int get() = pid
}

/** Una muestra completa de recursos del servidor. */
data class ServerResourceSample(
    val load1: Double,
    val load5: Double,
    val load15: Double,
    val cpu: CpuTicks,
    val cores: Int,
    val memory: ResourceUsage,
    val swap: ResourceUsage,
    val disk: ResourceUsage,
    val uptimeSeconds: Long,
    val topProcesses: List<ResourceProcess>,
)

/** Errores del monitor (port de `ServerResourceError`). */
sealed class ServerResourceException(message: String) : Exception(message) {
    /** Sin `/proc` (servidor no Linux) o salida incompleta. */
    class Unsupported :
        ServerResourceException("No se pudieron leer los recursos: el monitor necesita un servidor Linux (/proc).")
}
