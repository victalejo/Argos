package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/AgentReducerTests.swift`: reducer puro y determinista. */
class AgentReducerTest {

    private val request = AgentPermissionRequest("r1", "Write", null, EmptyJsonObject, null)

    @Test
    fun `estado inicial listo (idle) y vacio`() {
        val state = AgentConversationState()
        assertEquals(AgentStatus.Idle, state.status)
        assertTrue(state.items.isEmpty())
        assertNull(state.pendingPermission)
    }

    @Test
    fun `init fija session_id y pasa a idle`() {
        val state = AgentReducer.apply(AgentStreamEvent.Initialized(AgentInit("s1", "m")), AgentConversationState())
        assertEquals("s1", state.sessionID)
        assertEquals(AgentStatus.Idle, state.status)
    }

    @Test
    fun `init desde connecting pasa a idle`() {
        val connecting = AgentConversationState(status = AgentStatus.Connecting)
        val state = AgentReducer.apply(AgentStreamEvent.Initialized(AgentInit("s1", null)), connecting)
        assertEquals(AgentStatus.Idle, state.status)
    }

    @Test
    fun `texto del asistente se anade y thinking vacio se ignora`() {
        val event = AgentStreamEvent.Assistant(
            listOf(AgentContentBlock.Thinking(""), AgentContentBlock.Text("hola"), AgentContentBlock.Text("")),
        )
        val state = AgentReducer.apply(event, AgentConversationState())
        assertEquals(1, state.items.size)
        assertEquals(AgentTranscriptItem.Kind.AssistantText("hola"), state.items.first().kind)
        assertEquals(0, state.items.first().id)
    }

    @Test
    fun `tool_use se anade con nombre e input`() {
        val input = JsonObject(mapOf("command" to JsonPrimitive("ls")))
        val state = AgentReducer.apply(
            AgentStreamEvent.Assistant(listOf(AgentContentBlock.ToolUse("t", "Bash", input))),
            AgentConversationState(),
        )
        assertEquals(AgentTranscriptItem.Kind.ToolUse("Bash", input), state.items.first().kind)
    }

    @Test
    fun `permissionRequest fija el permiso pendiente`() {
        val state = AgentReducer.apply(AgentStreamEvent.PermissionRequest(request), AgentConversationState())
        assertEquals(request, state.pendingPermission)
    }

    @Test
    fun `permissionCancel limpia solo si coincide el id`() {
        val pending = AgentReducer.apply(AgentStreamEvent.PermissionRequest(request), AgentConversationState())
        val other = AgentReducer.apply(AgentStreamEvent.PermissionCancel("otro"), pending)
        assertEquals(request, other.pendingPermission) // no coincide: intacto
        val cleared = AgentReducer.apply(AgentStreamEvent.PermissionCancel("r1"), other)
        assertNull(cleared.pendingPermission) // coincide: limpio
    }

    @Test
    fun `result anade un item y vuelve a idle`() {
        val working = AgentConversationState(status = AgentStatus.Working)
        val state = AgentReducer.apply(AgentStreamEvent.Result(AgentResult("success", false, "ok", 0.1)), working)
        assertEquals(AgentStatus.Idle, state.status)
        assertEquals("ok", assertIs<AgentTranscriptItem.Kind.Result>(state.items.last().kind).result.text)
    }

    @Test
    fun `userSent anade el prompt y pasa a working`() {
        val state = AgentReducer.userSent("haz algo", AgentConversationState(status = AgentStatus.Idle))
        assertEquals(AgentTranscriptItem.Kind.UserText("haz algo"), state.items.last().kind)
        assertEquals(AgentStatus.Working, state.status)
    }

    @Test
    fun `finished con error marca failed y anade el error`() {
        val state = AgentReducer.finished("se cayó", AgentConversationState())
        assertEquals(AgentStatus.Failed("se cayó"), state.status)
        assertEquals(AgentTranscriptItem.Kind.Error("se cayó"), state.items.last().kind)
    }

    @Test
    fun `finished sin error marca finished y limpia el permiso`() {
        val pending = AgentConversationState(pendingPermission = request)
        val state = AgentReducer.finished(null, pending)
        assertEquals(AgentStatus.Finished, state.status)
        assertNull(state.pendingPermission)
    }

    @Test
    fun `ids incrementales y reduccion determinista`() {
        fun run(): AgentConversationState {
            var state = AgentReducer.apply(AgentStreamEvent.Initialized(AgentInit("s", null)), AgentConversationState())
            state = AgentReducer.userSent("hola", state)
            state = AgentReducer.apply(AgentStreamEvent.Assistant(listOf(AgentContentBlock.Text("respuesta"))), state)
            return AgentReducer.apply(AgentStreamEvent.Result(AgentResult("success", false, null, null)), state)
        }
        assertEquals(run(), run())
        assertEquals(listOf(0, 1, 2), run().items.map { it.id })
    }
}
