package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Codec puro del protocolo `stream-json` del CLI `claude` (port de
 * `ArgosCore/Agent/AgentProtocol.swift`): decodifica líneas NDJSON de stdout a
 * [AgentStreamEvent] y construye los mensajes que se escriben en stdin (prompt del
 * usuario y respuestas de permiso). Sin estado ni dependencias de red/UI.
 *
 * La codificación es BYTE A BYTE la del `JSONEncoder` de Swift con `.sortedKeys` (ver
 * [SwiftJson]): el servidor y `claude` son los mismos para Mac, iPhone y Android.
 */
object AgentProtocol {

    // MARK: Decodificación (stdout → eventos)

    /**
     * Decodifica una línea NDJSON. Devuelve `null` si la línea está vacía o no es un
     * objeto JSON con `type` (p. ej. una línea parcial o ruido).
     */
    fun decode(line: String): AgentStreamEvent? {
        val trimmed = SwiftText.trimWhitespaceAndNewlines(line)
        if (trimmed.isEmpty()) return null
        val element = runCatching { Json.parseToJsonElement(trimmed) }.getOrNull()
        val obj = element.objectOrNull ?: return null
        val type = obj["type"].stringOrNull ?: return null

        return when (type) {
            "system" -> if (obj["subtype"].stringOrNull == "init") {
                AgentStreamEvent.Initialized(
                    AgentInit(sessionID = obj["session_id"].stringOrNull ?: "", model = obj["model"].stringOrNull),
                )
            } else {
                AgentStreamEvent.Ignored(type, obj["subtype"].stringOrNull)
            }

            "assistant" -> AgentStreamEvent.Assistant(contentBlocks(obj["message"]))

            "user" -> userEvent(obj)

            "control_request" -> controlRequestEvent(obj)

            // Marca que Argos anexa al log del agente persistente al responder un permiso:
            // al releer el log, ese permiso ya no está pendiente.
            PersistentAgentScript.ANSWERED_EVENT_TYPE, "control_cancel_request" ->
                obj["request_id"].stringOrNull?.let { AgentStreamEvent.PermissionCancel(it) }
                    ?: AgentStreamEvent.Ignored(type, null)

            "result" -> AgentStreamEvent.Result(
                AgentResult(
                    subtype = obj["subtype"].stringOrNull ?: "",
                    isError = obj["is_error"].boolOrNull ?: false,
                    text = obj["result"].stringOrNull,
                    totalCostUSD = obj["total_cost_usd"].doubleOrNull,
                ),
            )

            "rate_limit_event" -> AgentStreamEvent.RateLimit

            else -> AgentStreamEvent.Ignored(type, obj["subtype"].stringOrNull)
        }
    }

    /**
     * Solo un prompt de PRIMER NIVEL escrito por el usuario conserva su texto (en el agente
     * persistente se pinta como burbuja suya). Los prompts que claude pasa a sus subagentes
     * (`parent_tool_use_id`) o los mensajes sintéticos/meta no deben hacerse pasar por el
     * usuario: de esos solo cuentan los resultados.
     */
    private fun userEvent(obj: JsonObject): AgentStreamEvent {
        val blocks = contentBlocks(obj["message"])
        val parent = obj["parent_tool_use_id"]
        val isSubagent = parent != null && parent != JsonNull
        val isSynthetic = obj["isMeta"].boolOrNull == true || obj["isSynthetic"].boolOrNull == true
        if (!isSubagent && !isSynthetic) return AgentStreamEvent.User(blocks)
        return AgentStreamEvent.User(blocks.filterIsInstance<AgentContentBlock.ToolResult>())
    }

    private fun controlRequestEvent(obj: JsonObject): AgentStreamEvent {
        val request = obj["request"].objectOrNull
        val requestID = obj["request_id"].stringOrNull
        val toolName = request?.get("tool_name").stringOrNull
        if (request == null || request["subtype"].stringOrNull != "can_use_tool" || requestID == null || toolName == null) {
            return AgentStreamEvent.Ignored("control_request", obj["request"].field("subtype").stringOrNull)
        }
        return AgentStreamEvent.PermissionRequest(
            AgentPermissionRequest(
                id = requestID,
                toolName = toolName,
                displayName = request["display_name"].stringOrNull,
                input = request["input"] ?: EmptyJsonObject,
                toolUseID = request["tool_use_id"].stringOrNull,
            ),
        )
    }

    /** Bloques de un `message` cuyo `content` puede ser texto plano o un array de bloques. */
    private fun contentBlocks(message: JsonElement?): List<AgentContentBlock> {
        val content = message.field("content") ?: return emptyList()
        content.stringOrNull?.let { text -> return if (text.isEmpty()) emptyList() else listOf(AgentContentBlock.Text(text)) }
        return content.arrayOrNull?.mapNotNull(::block) ?: emptyList()
    }

    private fun block(item: JsonElement): AgentContentBlock? {
        val obj = item.objectOrNull ?: return null
        return when (obj["type"].stringOrNull ?: return null) {
            "text" -> AgentContentBlock.Text(obj["text"].stringOrNull ?: "")
            "thinking" -> AgentContentBlock.Thinking(obj["thinking"].stringOrNull ?: "")
            "tool_use" -> {
                val id = obj["id"].stringOrNull ?: return null
                val name = obj["name"].stringOrNull ?: return null
                AgentContentBlock.ToolUse(id, name, obj["input"] ?: EmptyJsonObject)
            }
            "tool_result" -> {
                val toolUseID = obj["tool_use_id"].stringOrNull ?: return null
                AgentContentBlock.ToolResult(toolUseID, flattenedText(obj["content"]), obj["is_error"].boolOrNull ?: false)
            }
            else -> null
        }
    }

    /** Aplana el `content` de un tool_result (string o array de bloques de texto) a texto. */
    private fun flattenedText(value: JsonElement?): String {
        value.stringOrNull?.let { return it }
        return value.arrayOrNull?.mapNotNull { it.field("text").stringOrNull }?.joinToString("\n") ?: ""
    }

    // MARK: Codificación (app → stdin)

    /** Construye la línea NDJSON de un mensaje de usuario (prompt). */
    fun encodeUserMessage(text: String): String = SwiftJson.compact(
        jsonObjectOf(
            "type" to JsonPrimitive("user"),
            "message" to jsonObjectOf("role" to JsonPrimitive("user"), "content" to JsonPrimitive(text)),
        ),
    )

    /** Construye la línea NDJSON de la respuesta a una solicitud de permiso. */
    fun encodePermissionResponse(requestID: String, decision: AgentPermissionDecision): String {
        val inner = when (decision) {
            is AgentPermissionDecision.Allow ->
                jsonObjectOf("behavior" to JsonPrimitive("allow"), "updatedInput" to decision.updatedInput)
            is AgentPermissionDecision.Deny ->
                jsonObjectOf("behavior" to JsonPrimitive("deny"), "message" to JsonPrimitive(decision.message))
        }
        return SwiftJson.compact(
            jsonObjectOf(
                "type" to JsonPrimitive("control_response"),
                "response" to jsonObjectOf(
                    "subtype" to JsonPrimitive("success"),
                    "request_id" to JsonPrimitive(requestID),
                    "response" to inner,
                ),
            ),
        )
    }

    private fun jsonObjectOf(vararg pairs: Pair<String, JsonElement>): JsonObject = JsonObject(mapOf(*pairs))
}

/**
 * Acumula bytes de stdout y los parte en líneas completas (NDJSON), conservando el resto
 * incompleto (port de `NDJSONLineBuffer`). Inmutable: [append] devuelve el buffer
 * siguiente junto con las líneas listas. Una línea que no es UTF-8 válido se descarta,
 * como en Swift.
 */
class NdjsonLineBuffer private constructor(private val pending: ByteArray) {

    constructor() : this(ByteArray(0))

    /** Resultado de [append]: el buffer con el resto parcial y las líneas completas. */
    data class Appended(val buffer: NdjsonLineBuffer, val lines: List<String>)

    /** Añade un chunk de bytes y devuelve las líneas completas disponibles. */
    fun append(bytes: ByteArray): Appended {
        val data = pending + bytes
        val lines = mutableListOf<String>()
        var start = 0
        var newline = data.indexOf(start)
        while (newline >= 0) {
            decodeUtf8(data.copyOfRange(start, newline))?.let(lines::add)
            start = newline + 1
            newline = data.indexOf(start)
        }
        return Appended(NdjsonLineBuffer(data.copyOfRange(start, data.size)), lines)
    }

    private fun ByteArray.indexOf(from: Int): Int {
        for (i in from until size) if (this[i] == NEWLINE) return i
        return -1
    }

    private fun decodeUtf8(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }

    private companion object {
        const val NEWLINE: Byte = 0x0A
    }
}
