package com.iaportafolio.argos.core.doctor

import java.time.Instant

/**
 * Tipos (lógica pura) del Doctor del servidor (port de `ArgosCore/Doctor/DoctorModels.swift`):
 * estado de cada comprobación, el arreglo que se ofrece y el resultado completo. Las reglas de
 * severidad viven en [DoctorEvaluator]; las vistas solo pintan lo que aquí se decide.
 */
enum class DoctorStatus(val label: String) {
    OK("Correcto"),
    WARNING("Aviso"),
    PROBLEM("Problema"),

    /** No se pudo comprobar (falta una utilidad, permisos, otro sistema operativo…). */
    UNKNOWN("No se pudo comprobar"),
    ;

    /** 0 = correcto … 2 = problema; [UNKNOWN] no pesa (no es un fallo demostrado). */
    val severity: Int
        get() = when (this) {
            OK, UNKNOWN -> 0
            WARNING -> 1
            PROBLEM -> 2
        }
}

/** Identidad estable de cada comprobación (las vistas y los tests no dependen del texto). */
enum class DoctorCheckID {
    TMUX, GIT, CLAUDE, GH, TOOLS, PYTHON, DISK_HOME, DISK_TMP, MEMORY, SWAP, CLAUDE_PROCESSES,
    MAX_SESSIONS, FAIL2BAN, CLAUDE_HOOKS, PORTS_SKILL, PROJECTS_FILE, LOCALE, CLOCK,
}

/**
 * Qué se ofrece para arreglar una comprobación. Las acciones de un toque son SOLO las que Argos ya
 * sabe hacer de forma segura; el resto son comandos para copiar, nunca se ejecutan.
 */
sealed interface DoctorFix {
    /** Instala o actualiza los hooks de Claude de Argos. */
    data class InstallClaudeHooks(val isUpdate: Boolean) : DoctorFix

    /** Instala o actualiza la skill «argos-puertos» y su script. */
    data class InstallPortsSkill(val isUpdate: Boolean) : DoctorFix

    /** Comando que el usuario copia y ejecuta él mismo en el servidor. */
    data class CopyCommand(val command: String) : DoctorFix
}

data class DoctorCheck(
    val id: DoctorCheckID,
    val title: String,
    val status: DoctorStatus,
    /** Explicación corta (qué se encontró y por qué importa). */
    val detail: String,
    val fix: DoctorFix? = null,
)

/** Resultado de una pasada del Doctor. */
data class DoctorResult(val checks: List<DoctorCheck>, val finishedAt: Instant) {
    val problemCount: Int get() = checks.count { it.status == DoctorStatus.PROBLEM }
    val warningCount: Int get() = checks.count { it.status == DoctorStatus.WARNING }

    /** Peor estado de la pasada ([DoctorStatus.OK] si todo está bien o no se pudo comprobar). */
    val overall: DoctorStatus
        get() = when {
            problemCount > 0 -> DoctorStatus.PROBLEM
            warningCount > 0 -> DoctorStatus.WARNING
            else -> DoctorStatus.OK
        }

    val summary: String
        get() {
            val problems = if (problemCount == 1) "1 problema" else "$problemCount problemas"
            val warnings = if (warningCount == 1) "1 aviso" else "$warningCount avisos"
            return when {
                problemCount == 0 && warningCount == 0 -> "Todo en orden."
                problemCount == 0 -> "$warnings."
                warningCount == 0 -> "$problems."
                else -> "$problems y $warnings."
            }
        }

    /** Texto plano para pegar en un issue ([serverLabel] ya viene redactado si hace falta). */
    fun plainText(serverLabel: String): String {
        val lines = mutableListOf("Doctor del servidor: $serverLabel", "Resumen: $summary")
        for (check in checks) {
            lines += "[${check.status.label}] ${check.title}: ${check.detail}"
            (check.fix as? DoctorFix.CopyCommand)?.let { lines += "    Arreglo: ${it.command}" }
        }
        return lines.joinToString("\n")
    }
}

/** Versión numérica «a.b.c» extraída de la salida de `--version`. */
class DoctorVersion(val parts: List<Int>) : Comparable<DoctorVersion> {

    constructor(vararg parts: Int) : this(parts.toList())

    override fun compareTo(other: DoctorVersion): Int {
        for (index in 0 until maxOf(parts.size, other.parts.size)) {
            val left = parts.getOrElse(index) { 0 }
            val right = other.parts.getOrElse(index) { 0 }
            if (left != right) return left.compareTo(right)
        }
        return 0
    }

    /** 2.26 y 2.26.0 son la misma versión. */
    override fun equals(other: Any?): Boolean = other is DoctorVersion && compareTo(other) == 0

    override fun hashCode(): Int = parts.dropLastWhile { it == 0 }.hashCode()

    override fun toString(): String = text

    val text: String get() = parts.joinToString(".")

    companion object {
        private val PATTERN = Regex("""\d+(\.\d+)+""")

        /** Primera secuencia `N.N[.N…]` del texto («tmux 3.3a» → 3.3); `null` si no hay. */
        fun parse(text: String): DoctorVersion? {
            val match = PATTERN.find(text) ?: return null
            val numbers = match.value.split(".").mapNotNull(String::toIntOrNull)
            return if (numbers.isEmpty()) null else DoctorVersion(numbers)
        }
    }
}

/**
 * Comandos para COPIAR (nunca se ejecutan desde Argos) que instalan un paquete con el gestor que
 * detectó el script del Doctor (port de `DoctorInstallHints.swift`).
 */
object DoctorInstallHints {

    /** `sudo apt-get install -y tmux`, `brew install tmux`… o `null` si no se conoce el gestor. */
    fun install(packageName: String, packageManager: String?): String? = when (packageManager) {
        "apt-get" -> "sudo apt-get install -y $packageName"
        "dnf" -> "sudo dnf install -y $packageName"
        "yum" -> "sudo yum install -y $packageName"
        "pacman" -> "sudo pacman -S --noconfirm $packageName"
        "apk" -> "sudo apk add $packageName"
        "zypper" -> "sudo zypper install -y $packageName"
        "brew" -> "brew install $packageName"
        else -> null
    }

    /** Instalador oficial de Claude Code (script de instalación nativo). */
    const val CLAUDE_INSTALL = "curl -fsSL https://claude.ai/install.sh | bash"
}

/**
 * Parser (lógica pura) de la salida del script del Doctor: líneas `clave=valor` (port de
 * `DoctorFacts.swift`). Tolerante: ignora lo que no tenga ese formato (MOTD, avisos del perfil),
 * toma el PRIMER valor de cada clave.
 */
class DoctorFacts(private val values: Map<String, String>) {

    /** `true` si el script llegó al final (sin cortes por el camino). */
    val isComplete: Boolean get() = values["done"] == "1"

    /** Valor sin espacios sobrantes; `null` si falta o está vacío. */
    operator fun get(key: String): String? = values[key]?.trim(' ', '\t')?.takeIf { it.isNotEmpty() }

    /** `yes`/`no` → Boolean; cualquier otra cosa o ausencia → `null`. */
    fun flag(key: String): Boolean? = when (this[key]) {
        "yes" -> true
        "no" -> false
        else -> null
    }

    /** Enteros separados por espacios («total libre»). `null` si alguno no es un número ≥ 0. */
    fun numbers(key: String, count: Int): List<Long>? {
        val parts = this[key]?.split(" ")?.filter { it.isNotEmpty() } ?: return null
        if (parts.size != count) return null
        val numbers = parts.mapNotNull { part -> part.takeIf { it.all(Char::isDigit) }?.toLongOrNull() }
        return numbers.takeIf { it.size == count }
    }

    companion object {
        fun parse(output: String): DoctorFacts {
            val values = mutableMapOf<String, String>()
            for (line in output.split('\n', '\r').filter { it.isNotEmpty() }) {
                val equals = line.indexOf('=')
                if (equals < 0) continue
                val key = line.substring(0, equals)
                if (!isValidKey(key) || key in values) continue
                values[key] = line.substring(equals + 1)
            }
            return DoctorFacts(values)
        }

        /** Claves del script: `[a-z0-9._]+` (descarta ruido como `export FOO=bar`). */
        private fun isValidKey(key: String): Boolean =
            key.isNotEmpty() && key.all { it in 'a'..'z' || it in '0'..'9' || it == '.' || it == '_' }
    }
}
