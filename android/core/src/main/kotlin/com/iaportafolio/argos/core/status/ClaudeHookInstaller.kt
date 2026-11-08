package com.iaportafolio.argos.core.status

import com.iaportafolio.argos.core.agent.SwiftJson
import com.iaportafolio.argos.core.agent.SwiftText
import com.iaportafolio.argos.core.agent.stringOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Errores al fusionar los hooks de Argos en `~/.claude/settings.json`. */
sealed class ClaudeHookException(message: String) : Exception(message) {
    /** settings.json no es un objeto JSON válido: no se toca. */
    class InvalidSettings : ClaudeHookException(
        "~/.claude/settings.json del servidor no es un JSON válido; no se modificó. " +
            "Corrígelo y vuelve a intentarlo.",
    )
}

/**
 * Fusión (lógica pura) de los hooks de Argos en `~/.claude/settings.json` del servidor
 * (port de `ArgosCore/ClaudeStatus/ClaudeHookInstaller.swift`). Los hooks escriben el
 * estado de Claude en la opción de panel `@argos_claude` usando `$TMUX_PANE`; fuera de tmux
 * no hacen nada y siempre salen con 0 y sin stdout.
 *
 * Se identifican por [MARKER] en el comando: instalar primero quita los de Argos
 * (idempotente) y nunca toca los hooks propios del usuario. El settings se representa como
 * un [JsonObject] inmutable.
 */
object ClaudeHookInstaller {

    /** Marca que identifica los hooks instalados por Argos. */
    const val MARKER = "argos-claude-status"

    /** Opción de panel de tmux donde se guarda el estado. */
    const val OPTION = "@argos_claude"

    private const val HOOK_TIMEOUT_SECONDS = 5

    private data class Entry(val event: String, val matcher: String?, val state: ClaudeActivity?)

    /** Evento de Claude Code -> (matcher opcional, estado a escribir; `null` = borrar). */
    private val entries = listOf(
        Entry("UserPromptSubmit", null, ClaudeActivity.WORKING),
        Entry("PostToolUse", null, ClaudeActivity.WORKING),
        Entry("PermissionRequest", null, ClaudeActivity.WAITING),
        Entry(
            "Notification",
            "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
            ClaudeActivity.WAITING,
        ),
        Entry("Stop", null, ClaudeActivity.DONE),
        Entry("SessionEnd", null, null),
    )

    /** Comando del hook. Sin `$TMUX_PANE` (Claude fuera de tmux) no hace nada. */
    fun command(state: ClaudeActivity?): String {
        val action = state?.let { "set-option -p -t \"\$TMUX_PANE\" $OPTION ${it.rawValue}" }
            ?: "set-option -pu -t \"\$TMUX_PANE\" $OPTION"
        return "[ -n \"\$TMUX_PANE\" ] && tmux $action >/dev/null 2>&1; exit 0 # $MARKER"
    }

    // MARK: (De)serialización

    /**
     * Vacío -> objeto vacío.
     *
     * @throws ClaudeHookException.InvalidSettings si no es JSON válido o no es un objeto.
     */
    fun parseSettings(text: String): JsonObject {
        if (SwiftText.trimWhitespaceAndNewlines(text).isEmpty()) return JsonObject(emptyMap())
        return runCatching { Json.parseToJsonElement(text) }.getOrNull() as? JsonObject
            ?: throw ClaudeHookException.InvalidSettings()
    }

    /** Igual que `JSONSerialization` con `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` + `\n`. */
    fun serialize(settings: JsonObject): String =
        SwiftJson.pretty(settings, escapeSlashes = false, numbers = SwiftJson.Numbers.PRINTF_17G) + "\n"

    // MARK: Fusión

    /** ¿Están todos los hooks de Argos presentes? */
    fun isInstalled(settings: JsonObject): Boolean {
        val hooks = settings["hooks"] as? JsonObject ?: JsonObject(emptyMap())
        return entries.all { entry -> groups(hooks[entry.event]).any { group -> handlers(group).any(::isOurs) } }
    }

    /** Devuelve [settings] con los hooks de Argos (re)instalados. */
    fun installing(settings: JsonObject): JsonObject {
        val result = removing(settings)
        val initial = result["hooks"] as? JsonObject ?: JsonObject(emptyMap())
        val hooks = entries.fold(initial) { current, entry ->
            val handler = JsonObject(
                mapOf(
                    "type" to JsonPrimitive("command"),
                    "command" to JsonPrimitive(command(entry.state)),
                    "timeout" to JsonPrimitive(HOOK_TIMEOUT_SECONDS),
                ),
            )
            val group = JsonObject(
                listOfNotNull(
                    "hooks" to JsonArray(listOf(handler)),
                    entry.matcher?.let { "matcher" to JsonPrimitive(it) },
                ).toMap(),
            )
            JsonObject(current + (entry.event to JsonArray(groups(current[entry.event]) + group)))
        }
        return JsonObject(result + ("hooks" to hooks))
    }

    /** Devuelve [settings] sin los hooks de Argos (conserva los del usuario). */
    fun removing(settings: JsonObject): JsonObject {
        val hooks = settings["hooks"] as? JsonObject ?: return settings
        val cleanedHooks = hooks.entries.mapNotNull { (event, value) ->
            val eventGroups = groupsOrNull(value) ?: return@mapNotNull event to value // forma ajena: intacta
            val cleaned = eventGroups.mapNotNull(::withoutOurs)
            if (cleaned.isEmpty()) null else event to JsonArray(cleaned)
        }.toMap()
        return if (cleanedHooks.isEmpty()) {
            JsonObject(settings - "hooks")
        } else {
            JsonObject(settings + ("hooks" to JsonObject(cleanedHooks)))
        }
    }

    /** El grupo sin nuestros handlers: intacto si no tenía, `null` si solo tenía los nuestros. */
    private fun withoutOurs(group: JsonObject): JsonObject? {
        val original = handlers(group)
        val kept = original.filterNot(::isOurs)
        return when {
            kept.size == original.size -> group
            kept.isEmpty() -> null
            else -> JsonObject(group + ("hooks" to JsonArray(kept)))
        }
    }

    /** `value as? [[String: Any]]`: un array cuyos elementos son TODOS objetos. */
    private fun groupsOrNull(value: JsonElement?): List<JsonObject>? {
        val array = value as? JsonArray ?: return null
        return array.map { it as? JsonObject ?: return null }
    }

    private fun groups(value: JsonElement?): List<JsonObject> = groupsOrNull(value) ?: emptyList()

    private fun handlers(group: JsonObject): List<JsonObject> = groups(group["hooks"])

    private fun isOurs(handler: JsonObject): Boolean = handler["command"].stringOrNull?.contains(MARKER) ?: false
}
