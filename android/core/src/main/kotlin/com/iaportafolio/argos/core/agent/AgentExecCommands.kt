package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import java.text.Collator

/** Estado de autenticación de `claude` en un servidor (de `claude auth status --json`). */
data class ClaudeAuthStatus(
    val loggedIn: Boolean,
    /** Tipo de suscripción ("max", "pro", …) si está logueado con suscripción. */
    val subscriptionType: String?,
    val email: String?,
) {
    /** `true` si usa una suscripción de pago (no API/console). */
    val usesSubscription: Boolean get() = !subscriptionType.isNullOrEmpty()
}

/** Resultado de listar un directorio remoto: su ruta absoluta y sus subcarpetas. */
data class RemoteDirectoryListing(val path: String, val subdirectories: List<String>)

/** Errores del agente persistente (mismos mensajes que en Apple). */
enum class PersistentAgentError(val message: String) {
    NOT_RUNNING("El agente ya no está en marcha en el servidor. Reanúdalo para seguir la conversación."),
    CLAUDE_MISSING("Claude Code no está instalado en el servidor (no se encontró el comando «claude»)."),
    BUSY("Otro dispositivo está arrancando este agente ahora mismo. Inténtalo de nuevo en unos segundos."),
}

/**
 * Comandos y parsers PUROS del canal exec del agente (port de las partes sin red de
 * `ArgosCore/Agent/SSHAgentExec.swift`). Las cadenas son BYTE A BYTE las de Swift; la
 * ejecución por SSH vive en el módulo de red.
 */
object AgentExecCommands {

    /** Marca de stderr con la que `PersistentAgentScript.send` avisa de que el agente murió. */
    const val AGENT_DEAD_MARKER = "ARGOS_AGENT_DEAD"

    private const val DIRECTORY_OK_MARKER = "ARGOS_DIR_OK"

    /** Detalle de error del proceso `claude` remoto que incluye su stderr. */
    fun agentExecErrorMessage(detail: String): String = "El agente de Claude se cerró. Detalle del servidor:\n$detail"

    /**
     * Mata el proceso `claude` de un agente por su PID, comprobando ANTES que ese PID sigue
     * siendo un agente stream-json (el PID podría haberse reutilizado).
     */
    fun killAgentProcess(pid: Int): String =
        "ps -o args= -p $pid | grep -q -- '--input-format stream-json' " +
            "&& { kill -TERM $pid; sleep 2; kill -KILL $pid 2>/dev/null; } ; true"

    /** Memoria disponible (KB, `MemAvailable`); solo Linux. */
    const val AVAILABLE_MEMORY_COMMAND = "awk '/^MemAvailable:/ {print \$2}' /proc/meminfo 2>/dev/null"

    /** `Int(stdout.trimmed)`: KB disponibles o `null` (no Linux). */
    fun parseAvailableMemoryKB(stdout: String): Long? = SwiftText.trimWhitespaceAndNewlines(stdout).toLongOrNull()

    /**
     * Localiza `claude` en el servidor: prueba la shell de login del usuario y varias shells
     * comunes (para cargar el PATH), y si falla comprueba rutas de instalación conocidas.
     */
    val LOCATE_CLAUDE_SCRIPT: String = listOf(
        "for s in \"\$SHELL\" bash zsh sh; do",
        "  p=\$(\"\$s\" -lc 'command -v claude' 2>/dev/null | tail -n1)",
        "  case \"\$p\" in /*) echo \"\$p\"; exit 0;; esac",
        "done",
        "for c in \"\$HOME/.local/bin/claude\" \"\$HOME/.claude/local/claude\" " +
            "         \"\$HOME/.claude/bin/claude\" \"\$HOME/bin/claude\" " +
            "         \"/usr/local/bin/claude\" \"/opt/homebrew/bin/claude\" \"/usr/bin/claude\"; do",
        "  [ -x \"\$c\" ] && { echo \"\$c\"; exit 0; }",
        "done",
        "exit 1",
    ).joinToString("\n")

    /** Última línea que sea una ruta absoluta (tolera el ruido de los perfiles de login). */
    fun parseLocateClaude(stdout: String): String? =
        SwiftText.lines(stdout).map(SwiftText::trimWhitespace).lastOrNull { it.startsWith("/") }

    /** `pwd` + subcarpetas de [path] (expande `~` como el comando del agente). */
    fun listRemoteDirectories(path: String): String =
        "cd ${ClaudeAgentCommand.cdTarget(path)} 2>/dev/null && pwd && ls -1Ap 2>/dev/null | grep '/\$'"

    /**
     * Parsea la salida de [listRemoteDirectories]; `null` si no se pudo abrir el directorio.
     * Orden como `localizedCaseInsensitiveCompare` (colación del idioma, sin distinguir
     * mayúsculas).
     */
    fun parseRemoteDirectories(stdout: String): RemoteDirectoryListing? {
        val lines = SwiftText.lines(stdout)
        val pwd = lines.firstOrNull { it.startsWith("/") } ?: return null
        val collator = Collator.getInstance().apply { strength = Collator.SECONDARY }
        val subdirectories = lines
            .dropWhile { it != pwd }
            .drop(1)
            .map { it.removeSuffix("/") }
            .filter { it.isNotEmpty() }
            .sortedWith(collator::compare)
        return RemoteDirectoryListing(pwd, subdirectories)
    }

    /** ¿Existe [path] como directorio? (expande `~` igual que el comando del agente). */
    fun remoteDirectoryExists(path: String): String =
        "[ -d ${ClaudeAgentCommand.cdTarget(path)} ] && echo $DIRECTORY_OK_MARKER"

    fun parseRemoteDirectoryExists(stdout: String): Boolean = stdout.contains(DIRECTORY_OK_MARKER)

    /** `claude auth status --json` con el binario localizado. */
    fun claudeAuthStatus(claudePath: String): String = "${ShellQuoting.singleQuoted(claudePath)} auth status --json"

    /**
     * Interpreta la salida de [claudeAuthStatus] tolerando ruido alrededor del JSON. Sin
     * JSON parseable (o con un campo de tipo inesperado) cuenta como «no logueado».
     */
    fun parseAuthStatus(stdout: String): ClaudeAuthStatus {
        val notLoggedIn = ClaudeAuthStatus(loggedIn = false, subscriptionType = null, email = null)
        val json = extractJSONObject(stdout) ?: return notLoggedIn
        val obj = runCatching { Json.parseToJsonElement(json) }.getOrNull().objectOrNull ?: return notLoggedIn
        val loggedIn = optional(obj["loggedIn"]) { it.boolOrNull } ?: return notLoggedIn
        val subscription = optional(obj["subscriptionType"]) { it.stringOrNull } ?: return notLoggedIn
        val email = optional(obj["email"]) { it.stringOrNull } ?: return notLoggedIn
        return ClaudeAuthStatus(loggedIn.value ?: false, subscription.value, email.value)
    }

    /** Un campo opcional de `Decodable`: ausente o `null` → valor nulo; tipo erróneo → fallo. */
    private data class Field<T>(val value: T?)

    private fun <T> optional(element: JsonElement?, read: (JsonElement) -> T?): Field<T>? = when (element) {
        null, JsonNull -> Field(null)
        else -> read(element)?.let { Field(it) }
    }

    /** Extrae la subcadena del primer `{` al último `}` (descarta ruido de perfil/avisos). */
    fun extractJSONObject(text: String): String? {
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        if (start < 0 || end < 0 || start >= end) return null
        return text.substring(start, end + 1)
    }

    /** ¿Indica este stderr que el agente persistente ya no corre? */
    fun isAgentDead(stderr: String): Boolean = stderr.contains(AGENT_DEAD_MARKER)
}
