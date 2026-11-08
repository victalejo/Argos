package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive

/**
 * Construcción pura del comando remoto que lanza `claude` headless en modo stream-json
 * (port de `ArgosCore/Agent/ClaudeAgentCommand.swift`). Las cadenas son BYTE A BYTE las de
 * Swift.
 *
 * SEGURIDAD: en [build] el token de suscripción viaja como asignación de entorno en la
 * propia línea de comando (`CLAUDE_CODE_OAUTH_TOKEN=…`), visible vía `ps` para el MISMO
 * usuario y root. El agente persistente ([persistent]) lo recibe por stdin.
 */
object ClaudeAgentCommand {

    /** Modo de permisos con el que arranca el agente. */
    enum class PermissionMode(val rawValue: String) {
        /** Pregunta por cada herramienta no pre-aprobada (botones en la UI). */
        DEFAULT("default"),

        /** Auto-aprueba ediciones de archivos; pregunta el resto. */
        ACCEPT_EDITS("acceptEdits"),

        /** Solo lectura/exploración. */
        PLAN("plan"),

        /** Todos los permisos (el CLI lo rechaza si el usuario remoto es root). */
        BYPASS_PERMISSIONS("bypassPermissions"),
    }

    /** Banderas base, comunes a toda invocación headless con protocolo de control. */
    val baseFlags: List<String> = listOf(
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--permission-prompt-tool", "stdio",
    )

    /** Tipo de la línea NDJSON con la que el comando anuncia el PID del agente. */
    const val PID_EVENT_TYPE = "argos_pid"

    /**
     * Línea de comando completa para ejecutar por SSH (canal exec).
     *
     * @param claudePath ruta absoluta del binario `claude` en el servidor.
     * @param workingDirectory directorio de trabajo remoto (repo) donde corre el agente.
     * @param oauthToken token de suscripción; si es `null`/vacío se usa el `claude login`
     *   guardado en el SERVIDOR.
     * @param sessionID UUID de la sesión (permite reanudar luego con `--resume`).
     */
    fun build(
        claudePath: String,
        workingDirectory: String,
        oauthToken: String?,
        sessionID: String,
        permissionMode: PermissionMode = PermissionMode.BYPASS_PERMISSIONS,
    ): String {
        val directory = cdTarget(workingDirectory)
        val binary = ShellQuoting.singleQuoted(claudePath)
        val flags = (baseFlags + listOf("--permission-mode", permissionMode.rawValue, "--session-id", sessionID))
            .joinToString(" ")
        // `env -u ANTHROPIC_API_KEY` GARANTIZA que nunca se facture contra la API.
        val token = if (!oauthToken.isNullOrEmpty()) "CLAUDE_CODE_OAUTH_TOKEN=${ShellQuoting.singleQuoted(oauthToken)} " else ""
        val environment = "env -u ANTHROPIC_API_KEY $token"
        // `exec` conserva el PID de la shell: el anunciado es el del propio `claude`.
        val announcePID = "echo \"{\\\"type\\\":\\\"$PID_EVENT_TYPE\\\",\\\"pid\\\":\$\$}\""
        return "cd $directory && $announcePID && exec $environment$binary $flags"
    }

    /**
     * Invocación de `claude` para un agente PERSISTENTE (ver [PersistentAgentScript]): sin
     * `cd` ni anuncio de PID (los pone el lanzador) y con `--replay-user-messages`. Con
     * [resume] reanuda una conversación existente. El token NO va aquí (llega por stdin).
     */
    fun persistent(
        claudePath: String,
        sessionID: String,
        resume: Boolean,
        permissionMode: PermissionMode = PermissionMode.DEFAULT,
    ): String {
        val flags = (
            baseFlags + listOf(
                "--replay-user-messages",
                "--permission-mode", permissionMode.rawValue,
                if (resume) "--resume" else "--session-id", sessionID,
            )
            ).joinToString(" ")
        return "env -u ANTHROPIC_API_KEY ${ShellQuoting.singleQuoted(claudePath)} $flags"
    }

    /** PID anunciado por el comando, si [line] es esa línea (2…Int32.MAX). */
    fun announcedPID(line: String): Int? {
        if (!line.contains(PID_EVENT_TYPE)) return null
        val obj = runCatching { Json.parseToJsonElement(line) }.getOrNull().objectOrNull ?: return null
        if (obj["type"].stringOrNull != PID_EVENT_TYPE) return null
        val pid = (obj["pid"] as? JsonPrimitive)?.takeIf { !it.isString }?.let(::exactInteger) ?: return null
        return if (pid > 1 && pid <= Int.MAX_VALUE) pid.toInt() else null
    }

    /** Un número JSON que representa exactamente un entero (como `NSNumber as? Int`). */
    private fun exactInteger(primitive: JsonPrimitive): Long? {
        primitive.content.toLongOrNull()?.let { return it }
        val value = primitive.content.toDoubleOrNull() ?: return null
        return if (value == Math.rint(value) && Math.abs(value) < 9.0E18) value.toLong() else null
    }

    /**
     * Argumento de `cd` expandiendo `~`: `~` NO se expande entre comillas simples, así que
     * se traduce a `"$HOME"` y solo se entrecomilla el resto de la ruta (anti-inyección).
     */
    fun cdTarget(path: String): String {
        val trimmed = SwiftText.trimWhitespace(path)
        if (trimmed == "~" || trimmed.isEmpty()) return "\"\$HOME\""
        if (trimmed.startsWith("~/")) return "\"\$HOME\"/" + ShellQuoting.singleQuoted(trimmed.substring(2))
        return ShellQuoting.singleQuoted(trimmed)
    }
}
