package com.iaportafolio.argos.core.doctor

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Reglas del Doctor sobre recursos y sistema (port de `DoctorEvaluator+System.swift`): disco,
 * memoria, swap, procesos de Claude, `MaxSessions` de sshd, fail2ban, locale y desfase de reloj.
 */
object DoctorSystemRules {

    // MARK: Umbrales (KB salvo que se diga otra cosa)

    const val HOME_WARNING_KB = 1_024L * 1_024
    const val HOME_PROBLEM_KB = 200L * 1_024
    const val TMP_WARNING_KB = 200L * 1_024
    const val TMP_PROBLEM_KB = 50L * 1_024
    const val MEMORY_WARNING_KB = 1_024L * 1_024
    const val MEMORY_PROBLEM_KB = 300L * 1_024

    /** Con menos RAM que esto, no tener swap es un aviso. */
    const val SWAPLESS_RAM_LIMIT_KB = 4L * 1_024 * 1_024

    /** Fracción de la RAM que suman los procesos `claude` para avisar / dar problema. */
    const val CLAUDE_MEMORY_WARNING_FRACTION = 0.4
    const val CLAUDE_MEMORY_PROBLEM_FRACTION = 0.7
    const val SWAP_FULL_FRACTION = 0.8
    const val CLOCK_WARNING_SECONDS = 60.0
    const val CLOCK_PROBLEM_SECONDS = 300.0

    /** `MaxSessions` por defecto de OpenSSH. */
    private const val OPENSSH_DEFAULT_SESSIONS = 10
    private const val LINUX_ONLY = "Solo se puede leer en servidores Linux (/proc/meminfo)."

    // MARK: Disco

    fun diskHome(facts: DoctorFacts): DoctorCheck = disk(
        DoctorCheckID.DISK_HOME, "Disco libre en \$HOME", facts.numbers("disk.home", 2),
        HOME_WARNING_KB, HOME_PROBLEM_KB, "Las sesiones, los agentes y los proyectos escriben ahí.",
    )

    fun diskTmp(facts: DoctorFacts): DoctorCheck = disk(
        DoctorCheckID.DISK_TMP, "Disco libre en /tmp", facts.numbers("disk.tmp", 2),
        TMP_WARNING_KB, TMP_PROBLEM_KB, "Las subidas de archivos y capturas pasan por /tmp.",
    )

    private fun disk(id: DoctorCheckID, title: String, numbers: List<Long>?, warning: Long, problem: Long, impact: String): DoctorCheck {
        if (numbers == null) return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo leer el espacio libre (df).")
        val free = numbers[1]
        val text = "${formatKB(free)} libres de ${formatKB(numbers[0])}."
        return when {
            free < problem -> DoctorCheck(id, title, DoctorStatus.PROBLEM, "Casi sin espacio: $text $impact")
            free < warning -> DoctorCheck(id, title, DoctorStatus.WARNING, "Poco espacio: $text $impact")
            else -> DoctorCheck(id, title, DoctorStatus.OK, text)
        }
    }

    // MARK: Memoria

    /** `mem` = «total disponible swapTotal swapLibre» en KB (solo Linux, de /proc/meminfo). */
    private fun memoryNumbers(facts: DoctorFacts): List<Long>? = facts.numbers("mem", 4)?.takeIf { it[0] > 0 }

    fun memory(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.MEMORY
        val title = "Memoria disponible"
        val mem = memoryNumbers(facts) ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, LINUX_ONLY)
        val text = "${formatKB(mem[1])} disponibles de ${formatKB(mem[0])}."
        return when {
            mem[1] < MEMORY_PROBLEM_KB -> DoctorCheck(
                id, title, DoctorStatus.PROBLEM,
                "Memoria casi agotada: $text El sistema puede matar procesos (y sesiones tmux) sin avisar.",
            )
            mem[1] < MEMORY_WARNING_KB -> DoctorCheck(
                id, title, DoctorStatus.WARNING, "Memoria justa: $text Evita abrir más agentes de Claude.",
            )
            else -> DoctorCheck(id, title, DoctorStatus.OK, text)
        }
    }

    fun swap(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.SWAP
        val title = "Swap"
        val mem = memoryNumbers(facts) ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, LINUX_ONLY)
        if (mem[2] == 0L) {
            if (mem[0] < SWAPLESS_RAM_LIMIT_KB) {
                return DoctorCheck(
                    id, title, DoctorStatus.WARNING,
                    "Sin swap y con poca RAM (${formatKB(mem[0])}): un pico de memoria puede tumbar tus sesiones. Añade un archivo de swap.",
                )
            }
            return DoctorCheck(id, title, DoctorStatus.OK, "Sin swap (hay ${formatKB(mem[0])} de RAM).")
        }
        val used = maxOf(mem[2] - mem[3], 0)
        if (used.toDouble() / mem[2].toDouble() > SWAP_FULL_FRACTION) {
            return DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "Swap casi llena: ${formatKB(used)} usados de ${formatKB(mem[2])}. El servidor está corto de memoria.",
            )
        }
        return DoctorCheck(id, title, DoctorStatus.OK, "${formatKB(used)} usados de ${formatKB(mem[2])}.")
    }

    fun claudeProcesses(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.CLAUDE_PROCESSES
        val title = "Procesos de Claude"
        val procs = facts.numbers("claude.procs", 2)
            ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo listar los procesos (ps).")
        val count = procs[0]
        if (count <= 0) return DoctorCheck(id, title, DoctorStatus.OK, "Ningún proceso de Claude en marcha.")
        val text = "$count ${if (count == 1L) "proceso" else "procesos"} de Claude suman ${formatKB(procs[1])}."
        val mem = memoryNumbers(facts) ?: return DoctorCheck(id, title, DoctorStatus.OK, text)
        val fraction = procs[1].toDouble() / mem[0].toDouble()
        return when {
            fraction >= CLAUDE_MEMORY_PROBLEM_FRACTION -> DoctorCheck(
                id, title, DoctorStatus.PROBLEM, "$text Ocupan casi toda la RAM: cierra agentes que no uses.",
            )
            fraction >= CLAUDE_MEMORY_WARNING_FRACTION -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "$text Es mucha memoria: cierra agentes que no uses para no quedarte sin RAM.",
            )
            else -> DoctorCheck(id, title, DoctorStatus.OK, text)
        }
    }

    // MARK: sshd y fail2ban

    fun maxSessions(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.MAX_SESSIONS
        val title = "MaxSessions de sshd"
        return when (facts["sshd.config"]) {
            "readable" -> {
                val configured = facts["sshd.maxsessions"] ?: "default"
                val isDefault = configured == "default"
                val value = if (isDefault) OPENSSH_DEFAULT_SESSIONS else configured.toIntOrNull()
                    ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo interpretar el valor.")
                val origin = if (isDefault) " (valor por defecto de OpenSSH)" else ""
                val desired = DoctorEvaluator.DESIRED_SESSIONS
                if (value < desired) {
                    DoctorCheck(
                        id, title, DoctorStatus.WARNING,
                        "MaxSessions = $value$origin, menos de $desired. Argos se adapta, pero irá más lento al abrir varias cosas a la vez. Súbelo en sshd_config si puedes.",
                    )
                } else {
                    DoctorCheck(id, title, DoctorStatus.OK, "MaxSessions = $value$origin.")
                }
            }
            "unreadable" -> DoctorCheck(
                id, title, DoctorStatus.UNKNOWN,
                "No se pudo comprobar: /etc/ssh/sshd_config no es legible sin permisos de root.",
            )
            "missing" -> DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar: no hay /etc/ssh/sshd_config.")
            else -> DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar.")
        }
    }

    fun fail2ban(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.FAIL2BAN
        val title = "fail2ban"
        return when (facts["fail2ban"]) {
            "running" -> DoctorCheck(
                id, title, DoctorStatus.OK,
                "En marcha. Si Argos reconecta muchas veces seguidas con una clave mala, puede bloquearte.",
            )
            "installed" -> DoctorCheck(
                id, title, DoctorStatus.OK,
                "Instalado (no se pudo ver si está activo). Un exceso de intentos fallidos puede bloquear tu IP.",
            )
            "absent" -> DoctorCheck(id, title, DoctorStatus.OK, "No instalado (solo informativo).")
            else -> DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar.")
        }
    }

    // MARK: Locale y reloj

    fun locale(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.LOCALE
        val title = "Locale UTF-8"
        val env = facts.flag("locale.env") ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar.")
        if (env) return DoctorCheck(id, title, DoctorStatus.OK, "El entorno usa UTF-8.")
        val profile = DoctorFix.CopyCommand("echo 'export LANG=en_US.UTF-8' >> ~/.profile")
        return when (facts.flag("locale.avail")) {
            true -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "Hay locales UTF-8, pero el entorno no usa ninguno: una tmux sin UTF-8 rompe los acentos. Define LANG=en_US.UTF-8 en ~/.profile.",
                profile,
            )
            false -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "El servidor no tiene ningún locale UTF-8: una tmux sin UTF-8 rompe los acentos. Genera uno y defínelo.",
                DoctorFix.CopyCommand("sudo locale-gen en_US.UTF-8 && echo 'export LANG=en_US.UTF-8' >> ~/.profile"),
            )
            null -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "El entorno no declara UTF-8 (LANG vacío o distinto): una tmux sin UTF-8 rompe los acentos.",
                profile,
            )
        }
    }

    fun clock(facts: DoctorFacts, context: DoctorEvaluator.Context): DoctorCheck {
        val id = DoctorCheckID.CLOCK
        val title = "Reloj del servidor"
        val seconds = facts["clock"]?.toLongOrNull()?.takeIf { it > 0 }
            ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo leer la hora del servidor.")
        val skew = seconds.toDouble() - context.deviceNow.toEpochMilli() / MILLIS_PER_SECOND
        val magnitude = abs(skew)
        val direction = if (skew > 0) "adelantado" else "atrasado"
        val text = "El servidor va ${formatSeconds(magnitude)} $direction respecto a este dispositivo."
        return when {
            magnitude >= CLOCK_PROBLEM_SECONDS -> DoctorCheck(
                id, title, DoctorStatus.PROBLEM,
                "$text Los túneles, los avisos de Claude y las fechas de los commits saldrán desfasados. Activa la sincronización horaria (NTP).",
            )
            magnitude >= CLOCK_WARNING_SECONDS -> DoctorCheck(
                id, title, DoctorStatus.WARNING, "$text Conviene activar la sincronización horaria (NTP).",
            )
            else -> DoctorCheck(id, title, DoctorStatus.OK, "Desfase de ${formatSeconds(magnitude)}: correcto.")
        }
    }

    // MARK: Formato

    private const val MILLIS_PER_SECOND = 1_000.0
    private const val KB_PER_MB = 1_024.0
    private const val SECONDS_AS_MINUTES_FROM = 90

    fun formatKB(kb: Long): String {
        val mb = kb / KB_PER_MB
        return if (mb >= KB_PER_MB) {
            String.format(Locale.ROOT, "%.1f GB", mb / KB_PER_MB)
        } else {
            String.format(Locale.ROOT, "%.0f MB", mb)
        }
    }

    fun formatSeconds(seconds: Double): String =
        if (seconds < SECONDS_AS_MINUTES_FROM) "${seconds.roundToLong()} s" else "${(seconds / 60).roundToLong()} min"
}
