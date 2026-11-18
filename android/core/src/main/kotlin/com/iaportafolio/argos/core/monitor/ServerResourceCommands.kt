package com.iaportafolio.argos.core.monitor

/**
 * Comando del monitor de recursos (port de `SSHService.resourcesCommand` de
 * `ArgosCore/Monitor/SSHServerResources.swift`): vuelca `/proc`, `df` y `ps` en secciones separadas
 * por `@@`, un solo round-trip por refresco. Solo lectura; sin `/proc` la salida queda incompleta y
 * [ServerResourceParser.parse] lanza [ServerResourceException.Unsupported].
 */
object ServerResourceCommands {
    val COMMAND: String = listOf(
        "cat /proc/loadavg",
        "head -1 /proc/stat",
        "grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo",
        "nproc",
        "cut -d' ' -f1 /proc/uptime",
        "df -Pk / | tail -1",
        "ps -eo pid=,pcpu=,pmem=,comm= --sort=-pcpu | head -8",
    ).joinToString(" && echo '${ServerResourceParser.SEPARATOR}' && ")
}

/** Lectura de una muestra de recursos. Aparte de `SSHServicing` para no obligar a los dobles. */
interface ServerResourceReading {
    suspend fun resourceSample(): ServerResourceSample
}
