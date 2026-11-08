package com.iaportafolio.argos.core.monitor

/**
 * Comando y parser del monitor de recursos (port de `ArgosCore/Monitor/ServerResources.swift`
 * y `SSHServerResources.swift`). Los datos salen de `/proc` (Linux) en un único comando SSH
 * por el canal de comandos, con secciones separadas por líneas `@@`:
 * loadavg · línea `cpu` de /proc/stat · meminfo · nproc · uptime · df / · ps
 */
object ServerResourceParser {

    const val SEPARATOR = "@@"

    /**
     * Tope para cualquier contador/tamaño leído del servidor (2^53): de sobra para ticks de
     * CPU o KB reales, y lejos de `Long.MAX_VALUE`, así sumas y restas nunca desbordan.
     */
    const val MAX_COUNTER: Long = 1L shl 53

    private const val MIN_SECTIONS = 6
    private const val CPU_FIELDS = 8
    private const val MAX_UPTIME_SECONDS = Int.MAX_VALUE.toDouble() * 1000

    /**
     * Comando remoto del monitor. Solo lectura; si falta `/proc` (servidor no Linux) la
     * salida queda incompleta y [parse] lanza [ServerResourceException.Unsupported].
     */
    val RESOURCES_COMMAND: String = listOf(
        "cat /proc/loadavg",
        "head -1 /proc/stat",
        "grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo",
        "nproc",
        "cut -d' ' -f1 /proc/uptime",
        "df -Pk / | tail -1",
        "ps -eo pid=,pcpu=,pmem=,comm= --sort=-pcpu | head -8",
    ).joinToString(" && echo '$SEPARATOR' && ")

    private val whitespace = Regex("\\s+")

    /**
     * Parsea la salida de [RESOURCES_COMMAND]. Lanza [ServerResourceException.Unsupported]
     * si falta alguna sección obligatoria (la lista de procesos es opcional). La salida
     * remota no es de confianza: cualquier valor no representable se rechaza.
     */
    fun parse(output: String): ServerResourceSample {
        val sections = splitSections(output)
        if (sections.size < MIN_SECTIONS) throw ServerResourceException.Unsupported()
        val load = parseLoad(sections[0])
        val cpu = parseCpu(sections[1])
        val memory = parseMemory(sections[2])
        val cores = sections[3].firstOrNull()?.toIntOrNull()
        val uptime = sections[4].firstOrNull()?.let(::parseUptime)
        val disk = parseDisk(sections[5])
        if (load == null || cpu == null || memory == null || cores == null || uptime == null || disk == null) {
            throw ServerResourceException.Unsupported()
        }
        val processes = sections.getOrNull(MIN_SECTIONS)?.mapNotNull(::parseProcess).orEmpty()
        return ServerResourceSample(
            load1 = load.first, load5 = load.second, load15 = load.third,
            cpu = cpu,
            cores = cores,
            memory = memory.first,
            swap = memory.second,
            disk = disk,
            uptimeSeconds = uptime,
            topProcesses = processes,
        )
    }

    /** Grupos de líneas entre separadores; como `split` de Swift, sin grupos vacíos. */
    private fun splitSections(output: String): List<List<String>> {
        val groups = mutableListOf<List<String>>()
        var current = mutableListOf<String>()
        for (line in output.split("\n")) {
            if (line.trim() == SEPARATOR) {
                if (current.isNotEmpty()) groups += current
                current = mutableListOf()
            } else {
                current += line
            }
        }
        if (current.isNotEmpty()) groups += current
        return groups.map { group -> group.map { it.trim() }.filter { it.isNotEmpty() } }
    }

    private fun fields(line: String): List<String> = line.split(whitespace).filter { it.isNotEmpty() }

    private fun counter(text: String): Long? = text.toLongOrNull()?.takeIf { it in 0..MAX_COUNTER }

    /** Segundos de `/proc/uptime`. Rechaza `inf`/`nan`/negativos/enormes. */
    private fun parseUptime(text: String): Long? {
        val value = text.toDoubleOrNull() ?: return null
        if (!value.isFinite() || value < 0 || value >= MAX_UPTIME_SECONDS) return null
        return value.toLong()
    }

    private fun parseLoad(lines: List<String>): Triple<Double, Double, Double>? {
        val f = lines.firstOrNull()?.let(::fields) ?: return null
        if (f.size < 3) return null
        val l1 = f[0].toDoubleOrNull() ?: return null
        val l5 = f[1].toDoubleOrNull() ?: return null
        val l15 = f[2].toDoubleOrNull() ?: return null
        return Triple(l1, l5, l15)
    }

    /** `cpu user nice system idle iowait irq softirq steal …` — idle cuenta iowait. */
    private fun parseCpu(lines: List<String>): CpuTicks? {
        val f = lines.firstOrNull()?.let(::fields) ?: return null
        if (f.firstOrNull() != "cpu" || f.size < CPU_FIELDS + 1) return null
        val values = f.subList(1, CPU_FIELDS + 1).mapNotNull(::counter)
        if (values.size != CPU_FIELDS) return null
        return CpuTicks(total = values.sum(), idle = values[3] + values[4])
    }

    private fun parseMemory(lines: List<String>): Pair<ResourceUsage, ResourceUsage>? {
        val kb = buildMap {
            for (line in lines) {
                val f = fields(line)
                if (f.size < 2) continue
                val value = counter(f[1]) ?: continue
                put(f[0].dropLast(1), value) // "MemTotal:" -> "MemTotal"
            }
        }
        val memTotal = kb["MemTotal"] ?: return null
        val memAvailable = kb["MemAvailable"] ?: return null
        if (memAvailable > memTotal) return null
        val swapTotal = kb["SwapTotal"] ?: 0L
        val swapFree = minOf(kb["SwapFree"] ?: 0L, swapTotal)
        return ResourceUsage(memTotal - memAvailable, memTotal) to ResourceUsage(swapTotal - swapFree, swapTotal)
    }

    /** Línea de `df -Pk /`: `fs 1024-blocks used available capacity mount`. */
    private fun parseDisk(lines: List<String>): ResourceUsage? {
        val f = lines.lastOrNull()?.let(::fields) ?: return null
        if (f.size < 4) return null
        val total = counter(f[1]) ?: return null
        val used = counter(f[2]) ?: return null
        return ResourceUsage(usedKB = used, totalKB = total)
    }

    /** `pid pcpu pmem comm` — `comm` puede llevar espacios (p. ej. "tmux: server"). */
    private fun parseProcess(line: String): ResourceProcess? {
        val f = line.trim().split(whitespace, limit = 4)
        if (f.size != 4) return null
        val pid = f[0].toIntOrNull() ?: return null
        val cpu = f[1].toDoubleOrNull() ?: return null
        val mem = f[2].toDoubleOrNull() ?: return null
        return ResourceProcess(pid, cpu, mem, f[3])
    }
}
