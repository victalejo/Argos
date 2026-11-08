package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

/** Paridad con `ArgosTests/AgentProtocolTests.swift` (fragmentos reales de `claude` v2.1.183). */
class AgentProtocolTest {

    // Decodificación

    @Test
    fun `init se decodifica con session_id y model`() {
        val line = """{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-opus-4-8[1m]","cwd":"/tmp"}"""
        val event = assertIs<AgentStreamEvent.Initialized>(AgentProtocol.decode(line))
        assertEquals("abc-123", event.info.sessionID)
        assertEquals("claude-opus-4-8[1m]", event.info.model)
    }

    @Test
    fun `assistant con texto`() {
        val line = """{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hola"}]},"session_id":"s"}"""
        val event = assertIs<AgentStreamEvent.Assistant>(AgentProtocol.decode(line))
        assertEquals(listOf<AgentContentBlock>(AgentContentBlock.Text("hola")), event.blocks)
    }

    @Test
    fun `assistant con tool_use conserva nombre e input`() {
        val line = """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls","timeout":5}}]}}"""
        val event = assertIs<AgentStreamEvent.Assistant>(AgentProtocol.decode(line))
        val toolUse = assertIs<AgentContentBlock.ToolUse>(event.blocks.first())
        assertEquals("toolu_1", toolUse.id)
        assertEquals("Bash", toolUse.name)
        assertEquals("ls", toolUse.input.field("command").stringOrNull)
        assertEquals(JsonPrimitive(5), toolUse.input.field("timeout"))
    }

    @Test
    fun `control_request can_use_tool produce permissionRequest`() {
        val line = """{"type":"control_request","request_id":"req-9","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/tmp/x.txt","content":"H"},"tool_use_id":"toolu_2"}}"""
        val request = assertIs<AgentStreamEvent.PermissionRequest>(AgentProtocol.decode(line)).request
        assertEquals("req-9", request.id)
        assertEquals("Write", request.toolName)
        assertEquals("Write", request.displayName)
        assertEquals("toolu_2", request.toolUseID)
        assertEquals("/tmp/x.txt", request.input.field("file_path").stringOrNull)
    }

    @Test
    fun `control_cancel_request produce permissionCancel`() {
        val line = """{"type":"control_cancel_request","request_id":"req-9"}"""
        assertEquals(AgentStreamEvent.PermissionCancel("req-9"), AgentProtocol.decode(line))
    }

    @Test
    fun `result conserva subtype, error y costo`() {
        val line = """{"type":"result","subtype":"success","is_error":false,"result":"listo","total_cost_usd":0.21}"""
        val result = assertIs<AgentStreamEvent.Result>(AgentProtocol.decode(line)).result
        assertEquals("success", result.subtype)
        assertEquals(false, result.isError)
        assertEquals("listo", result.text)
        assertEquals(0.21, result.totalCostUSD)
    }

    @Test
    fun `user con tool_result`() {
        val line = """{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"salida","is_error":false}]}}"""
        val event = assertIs<AgentStreamEvent.User>(AgentProtocol.decode(line))
        assertEquals(listOf<AgentContentBlock>(AgentContentBlock.ToolResult("toolu_1", "salida", false)), event.blocks)
    }

    @Test
    fun `hooks y system no-init se ignoran`() {
        val line = """{"type":"system","subtype":"hook_started","hook_id":"h"}"""
        assertEquals(AgentStreamEvent.Ignored("system", "hook_started"), AgentProtocol.decode(line))
    }

    @ParameterizedTest
    @ValueSource(strings = ["", "   ", "no es json", "{roto"])
    fun `linea invalida o vacia devuelve null`(line: String) {
        assertNull(AgentProtocol.decode(line))
    }

    // Codificación

    @Test
    fun `encodeUserMessage produce el envelope correcto`() {
        val obj = Json.parseToJsonElement(AgentProtocol.encodeUserMessage("hola mundo")).jsonObject
        assertEquals("user", obj["type"].stringOrNull)
        val message = obj["message"]
        assertEquals("user", message.field("role").stringOrNull)
        assertEquals("hola mundo", message.field("content").stringOrNull)
    }

    @Test
    fun `encodePermissionResponse allow incluye updatedInput`() {
        val line = AgentProtocol.encodePermissionResponse(
            "req-9",
            AgentPermissionDecision.Allow(JsonObject(mapOf("command" to JsonPrimitive("ls")))),
        )
        val response = Json.parseToJsonElement(line).field("response").field("response")
        assertEquals("allow", response.field("behavior").stringOrNull)
        assertEquals("ls", response.field("updatedInput").field("command").stringOrNull)
    }

    @Test
    fun `encodePermissionResponse deny incluye mensaje y request_id`() {
        val obj = Json.parseToJsonElement(AgentProtocol.encodePermissionResponse("req-9", AgentPermissionDecision.Deny("no")))
        assertEquals("control_response", obj.field("type").stringOrNull)
        val outer = obj.field("response")
        assertEquals("success", outer.field("subtype").stringOrNull)
        assertEquals("req-9", outer.field("request_id").stringOrNull)
        val inner = outer.field("response")
        assertEquals("deny", inner.field("behavior").stringOrNull)
        assertEquals("no", inner.field("message").stringOrNull)
    }

    // Buffer NDJSON

    @Test
    fun `el buffer parte lineas completas y conserva el resto parcial`() {
        val first = NdjsonLineBuffer().append("""{"a":1}""".toByteArray())
        assertEquals(emptyList(), first.lines) // sin newline aún
        val second = first.buffer.append("\n{\"b\":2".toByteArray())
        assertEquals(listOf("""{"a":1}"""), second.lines) // cierra la 1ª
        val third = second.buffer.append("}\n".toByteArray())
        assertEquals(listOf("""{"b":2}"""), third.lines) // cierra la 2ª
    }

    @Test
    fun `el buffer maneja varias lineas en un solo chunk`() {
        assertEquals(listOf("uno", "dos", "tres"), NdjsonLineBuffer().append("uno\ndos\ntres\n".toByteArray()).lines)
    }

    @Test
    fun `el buffer no parte un caracter UTF-8 entre chunks y descarta lineas no UTF-8`() {
        val bytes = "ñandú\n".toByteArray()
        val first = NdjsonLineBuffer().append(bytes.copyOfRange(0, 1))
        assertEquals(listOf("ñandú"), first.buffer.append(bytes.copyOfRange(1, bytes.size)).lines)
        assertEquals(listOf("ok"), NdjsonLineBuffer().append(byteArrayOf(0xFF.toByte(), 0x0A) + "ok\n".toByteArray()).lines)
    }
}
