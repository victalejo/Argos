package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive

/**
 * Construcción pura del comando remoto que lanza `claude` headless en modo stream-json
 * (port de `ArgosCore/Agent/ClaudeAgentCommand.swift`). Las cadenas son BYTE A BYTE las de
 * Swift.
 *
 * SEGURIDAD: el token de suscripción viaja por stdin ([tokenLine]) y se exporta con un
 * builtin. La línea de comandos la puede leer cualquier usuario del servidor (`ps`), así que
 * el token nunca va en ella.
 */
object ClaudeAgentCommand {

    /** Modo de permisos con el que arranca el agente. */
    enum class PermissionMode(val rawValue: String) {
        /** Todos los permisos; el CLI lo rechaza con root: ver [modeArgument]. */
        BYPASS_PERMISSIONS("bypassPermissions"),

        /** Auto-aprueba ediciones de archivos; pregunta el resto. */
        ACCEPT_EDITS("acceptEdits"),

        /** Pregunta por cada herramienta no pre-aprobada (botones en la UI). */
        DEFAULT("default"),

        /** Solo lectura/exploración. */
        PLAN("plan"),
        ;

        companion object {
            /** Como `PermissionMode(rawValue:)`: `null` si el modo es desconocido. */
            fun fromRawValue(rawValue: String?): PermissionMode? = entries.firstOrNull { it.rawValue == rawValue }
        }
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
     * Línea de comando completa para ejecutar por SSH (canal exec). La PRIMERA línea de stdin
     * debe ser [tokenLine]: con token, se exporta; vacía, el CLI usa la credencial de
     * `claude login` guardada en el SERVIDOR.
     *
     * @param claudePath ruta absoluta del binario `claude` en el servidor.
     * @param workingDirectory directorio de trabajo remoto (repo) donde corre el agente.
     * @param sessionID UUID de la sesión (permite reanudar luego con `--resume`).
     */
    fun build(
        claudePath: String,
        workingDirectory: String,
        sessionID: String,
        permissionMode: PermissionMode = PermissionMode.BYPASS_PERMISSIONS,
    ): String {
        val directory = cdTarget(workingDirectory)
        val binary = ShellQuoting.singleQuoted(claudePath)
        val flags = (baseFlags + listOf("--permission-mode", modeArgument(permissionMode), "--session-id", sessionID))
            .joinToString(" ")
        // `env -u ANTHROPIC_API_KEY` GARANTIZA que nunca se facture contra la API.
        // `read` no consume más allá de la primera línea: el resto de stdin es para claude.
        val readToken = "IFS= read -r ARGOS_OAUTH; " +
            "[ -n \"\$ARGOS_OAUTH\" ] && export CLAUDE_CODE_OAUTH_TOKEN=\"\$ARGOS_OAUTH\"; unset ARGOS_OAUTH"
        // `exec` conserva el PID de la shell: el anunciado es el del propio `claude`.
        val announcePID = "echo \"{\\\"type\\\":\\\"$PID_EVENT_TYPE\\\",\\\"pid\\\":\$\$}\""
        return "cd $directory && $announcePID && { $readToken; exec env -u ANTHROPIC_API_KEY $binary $flags; }"
    }

    /**
     * Primera línea de stdin del comando: el token, o vacía si no hay. Sin saltos de línea ni
     * espacios: lo que siguiera a un salto le llegaría a claude como un prompt.
     */
    fun tokenLine(oauthToken: String?): ByteArray =
        ((oauthToken ?: "").filterNot { it.isWhitespace() } + "\n").toByteArray(Charsets.UTF_8)

    /**
     * Valor de `--permission-mode`. El CLI rechaza `bypassPermissions` con root y el agente no
     * llegaría a arrancar, así que con root se pregunta cada acción.
     */
    private fun modeArgument(mode: PermissionMode): String {
        if (mode != PermissionMode.BYPASS_PERMISSIONS) return mode.rawValue
        return "\"\$([ \"\$(id -u)\" = 0 ] && echo ${PermissionMode.DEFAULT.rawValue} || echo ${mode.rawValue})\""
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
                "--permission-mode", modeArgument(permissionMode),
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
