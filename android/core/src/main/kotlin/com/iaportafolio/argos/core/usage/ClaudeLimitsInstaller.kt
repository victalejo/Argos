package com.iaportafolio.argos.core.usage

import com.iaportafolio.argos.core.agent.SwiftText
import com.iaportafolio.argos.core.agent.stringOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Statusline de Argos para leer los límites de uso de Claude (lógica pura; port de
 * `ArgosCore/ClaudeUsage/ClaudeLimitsInstaller.swift`). Claude Code solo entrega `rate_limits`
 * (ventana de 5 h, semanal…) a su statusline, así que Argos pone la suya: un script que guarda ese
 * JSON en `~/.config/argos/claude-limits.json` y luego ejecuta la statusline que el usuario tuviera,
 * con la misma entrada (su barra se sigue viendo igual). Es opcional y se puede quitar: al quitarla
 * vuelve la anterior.
 *
 * El comando anterior se guarda en `~/.config/argos/statusline-previous`: una cabecera
 * ([PREVIOUS_HEADER]) y debajo el comando (vacío = no había). Sin cabecera, el archivo falta o no es
 * nuestro (p. ej. settings.json sincronizado desde otro servidor) y Argos se niega a quitar la
 * statusline para no perder la del usuario. El script y el formato los comparten Mac, iPhone/iPad y
 * Android (goldens `limits-*`): cambiarlos solo de forma aditiva. El settings se representa como un
 * [JsonObject] inmutable.
 */
object ClaudeLimitsInstaller {

    /** Marca del comando de Argos en `statusLine.command`. */
    const val MARKER = "argos-claude-limits"
    const val SCRIPT_RELATIVE_PATH = ".config/argos/statusline.sh"
    const val PREVIOUS_RELATIVE_PATH = ".config/argos/statusline-previous"
    const val LIMITS_RELATIVE_PATH = ".config/argos/claude-limits.json"

    /** Lo que se pone en `statusLine.command` (Claude Code lo ejecuta con un shell). */
    const val COMMAND = "sh \"\$HOME/$SCRIPT_RELATIVE_PATH\" # $MARKER"

    /**
     * Script de la statusline. POSIX sh (dash), sin jq ni python, y siempre sale con 0. Solo
     * reescribe el archivo cuando la entrada trae porcentajes (al arrancar Claude Code aún no los
     * tiene), y lo hace de forma atómica y privada (0600).
     */
    val SCRIPT: String = """
        # $MARKER: Argos guarda los límites de uso de Claude (rate_limits) que Claude Code
        # pasa a la statusline y después ejecuta la statusline anterior del usuario.
        d="${'$'}HOME/.config/argos"
        i=${'$'}(cat)
        case ${'$'}i in
        *'"rate_limits"'*'"used_percentage"'*)
          umask 077
          t="${'$'}d/claude-limits.json.${'$'}${'$'}"
          mkdir -p "${'$'}d" 2>/dev/null && { date +%s; printf '%s\n' "${'$'}i"; } > "${'$'}t" 2>/dev/null \
            && mv -f "${'$'}t" "${'$'}d/claude-limits.json" 2>/dev/null || rm -f "${'$'}t" 2>/dev/null
          ;;
        esac
        p=${'$'}(sed 1d "${'$'}d/statusline-previous" 2>/dev/null)
        [ -n "${'$'}p" ] && printf '%s' "${'$'}i" | sh -c "${'$'}p"
        exit 0
    """.trimIndent() + "\n"

    /**
     * Cuerpo de la sección `limits` del sondeo: hora del servidor y el archivo, solo si la statusline
     * de Argos sigue puesta (tras quitarla no se enseñan datos viejos).
     */
    const val POLL_COMMAND = "printf 'now %s\\n' \"\$(date +%s)\"; " +
        "grep -qs '$MARKER' \"\$HOME/.claude/settings.json\" && cat \"\$HOME/$LIMITS_RELATIVE_PATH\" 2>/dev/null"

    // MARK: Comando anterior

    /** Primera línea del archivo del comando anterior. */
    const val PREVIOUS_HEADER = "# $MARKER statusline-previous v1"

    /** Contenido del archivo: cabecera y el comando (`""` = no había statusline). */
    fun previousFileContents(command: String): String = "$PREVIOUS_HEADER\n$command\n"

    /** Comando anterior guardado. `null` si el archivo falta o no lleva la cabecera. */
    fun previousCommand(fromFile: String): String? {
        val lines = fromFile.split("\n")
        if (lines.first() != PREVIOUS_HEADER) return null
        return SwiftText.trimWhitespaceAndNewlines(lines.drop(1).joinToString("\n"))
    }

    // MARK: Estado

    /** ¿Está puesta la statusline de Argos (de cualquier versión)? */
    fun isInstalled(settings: JsonObject): Boolean = statusLineCommand(settings)?.contains(MARKER) ?: false

    /** ¿Está puesta y con el comando actual? */
    fun isCurrent(settings: JsonObject): Boolean = statusLineCommand(settings) == COMMAND

    private fun statusLineCommand(settings: JsonObject): String? = (settings["statusLine"] as? JsonObject)?.get("command").stringOrNull

    // MARK: Fusión

    /**
     * Resultado de instalar: settings nuevos y, si hay que escribirlo, el comando anterior que la
     * statusline de Argos debe seguir ejecutando (`""` = no había; `null` = no tocar el archivo:
     * ya estaba instalada y se conserva lo guardado).
     */
    data class Installation(val settings: JsonObject, val previousCommand: String?)

    /** Pone la statusline de Argos y conserva el resto de `statusLine` (padding…) y de settings. */
    fun installing(settings: JsonObject): Installation {
        val statusLine = settings["statusLine"] as? JsonObject ?: JsonObject(emptyMap())
        val existing = statusLine["command"].stringOrNull
        val wasOurs = existing?.contains(MARKER) ?: false
        val updated = JsonObject(statusLine + mapOf("type" to JsonPrimitive("command"), "command" to JsonPrimitive(COMMAND)))
        return Installation(JsonObject(settings + ("statusLine" to updated)), if (wasOurs) null else existing ?: "")
    }

    /**
     * Quita la statusline de Argos y devuelve la anterior ([previousCommand], ya leída del archivo;
     * `""` = no había, y entonces se quita `statusLine`). Si la actual no es la de Argos, no toca nada.
     */
    fun removing(settings: JsonObject, previousCommand: String): JsonObject {
        if (!isInstalled(settings)) return settings
        val restored = SwiftText.trimWhitespaceAndNewlines(previousCommand)
        if (restored.isEmpty()) return JsonObject(settings - "statusLine")
        val statusLine = settings["statusLine"] as? JsonObject ?: JsonObject(emptyMap())
        return JsonObject(settings + ("statusLine" to JsonObject(statusLine + ("command" to JsonPrimitive(restored)))))
    }
}

/** Estado de la statusline de límites en un servidor. */
sealed interface ClaudeLimitsInstallState {
    data object Inactive : ClaudeLimitsInstallState
    data object Active : ClaudeLimitsInstallState

    /**
     * Está en settings.json pero falta el script, es de otra versión o falta el comando anterior
     * guardado (p. ej. settings.json copiado o sincronizado desde otro servidor).
     */
    data class NeedsRepair(val previousMissing: Boolean) : ClaudeLimitsInstallState

    companion object {
        /** Decide el estado con settings.json y los archivos del servidor (`""` = no existe). */
        fun of(settings: JsonObject, previousFile: String, script: String): ClaudeLimitsInstallState {
            if (!ClaudeLimitsInstaller.isInstalled(settings)) return Inactive
            val previousMissing = ClaudeLimitsInstaller.previousCommand(previousFile) == null
            val outdated = script != ClaudeLimitsInstaller.SCRIPT || !ClaudeLimitsInstaller.isCurrent(settings)
            return if (previousMissing || outdated) NeedsRepair(previousMissing) else Active
        }
    }
}

/** Fallos propios de poner o quitar la statusline (mensajes como los de Swift). */
sealed class ClaudeLimitsException(message: String) : Exception(message) {
    /** Sin la cabecera del comando anterior no se sabe cuál era la barra del usuario: no se toca. */
    class PreviousMissing : ClaudeLimitsException(
        "Falta ~/.config/argos/statusline-previous en este servidor (¿settings.json copiado o sincronizado " +
            "desde otro?), así que Argos no sabe cuál era tu barra de estado y no la toca. Quítala desde el " +
            "servidor donde la activaste o restaura ~/.claude/settings.json.argos-backup.",
    )

    /** settings.json cambió entre leerlo y escribirlo: no se pisa. */
    class SettingsChanged : ClaudeLimitsException(
        "~/.claude/settings.json cambió mientras Argos lo editaba (¿Claude Code o otro dispositivo?). " +
            "No se modificó: vuelve a intentarlo.",
    )
}

/**
 * Activar, quitar y leer los límites de Claude de un servidor (port de
 * `ArgosCore/ClaudeUsage/SSHClaudeLimits.swift` y de la sección `limits` del sondeo). Aparte de
 * [com.iaportafolio.argos.core.SSHServicing] para no obligar a los dobles de prueba.
 */
interface ClaudeLimitsAccess {
    /** ¿Está puesta la statusline de Argos en el servidor, y completa? */
    suspend fun claudeLimitsState(): ClaudeLimitsInstallState

    /**
     * Instala, actualiza o repara la statusline de Argos conservando la del usuario. Si ya estaba
     * puesta, nunca inventa el comando anterior: solo reescribe el script.
     */
    suspend fun installClaudeLimits()

    /**
     * Quita la statusline de Argos, devuelve la anterior y borra los límites guardados.
     *
     * @throws ClaudeLimitsException.PreviousMissing si falta la cabecera del comando anterior.
     */
    suspend fun uninstallClaudeLimits()

    /**
     * Lee los límites guardados (`null` = sin statusline de Argos o aún sin datos). Si el comando no
     * llega a responder, LANZA: así se distingue «no hay» de «no se leyó» (`limitsChecked` en Swift).
     */
    suspend fun claudeLimits(): ClaudeLimitsReading?
}
