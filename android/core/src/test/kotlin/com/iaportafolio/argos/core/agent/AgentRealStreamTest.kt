package com.iaportafolio.argos.core.agent

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Paridad con `ArgosTests/AgentRealStreamTests.swift`: reproduce una sesión REAL de
 * `claude -p --input-format stream-json` (3 turnos: saludo, Write con permiso concedido y
 * Bash con permiso denegado) desde el fixture `agent-stream-real.ndjson`.
 */
class AgentRealStreamTest {

    private fun lines(): List<String> {
        val resource = assertNotNull(javaClass.getResource("/agent-stream-real.ndjson"))
        return SwiftText.lines(resource.readText(Charsets.UTF_8))
    }

    @Test
    fun `todas las lineas se decodifican (las desconocidas como ignored)`() {
        val lines = lines()
        assertEquals(33, lines.size)
        for (line in lines) {
            assertNotNull(AgentProtocol.decode(line), "no decodifica: ${line.take(80)}")
        }
    }

    @Test
    fun `el reducer reconstruye los 3 turnos y los permisos`() {
        val events = lines().mapNotNull(AgentProtocol::decode)
        val state = events.fold(AgentConversationState()) { current, event -> AgentReducer.apply(event, current) }
        val permissionTools = events.filterIsInstance<AgentStreamEvent.PermissionRequest>().map { it.request.toolName }

        assertEquals(3, state.items.count { it.kind is AgentTranscriptItem.Kind.Result })
        assertTrue(state.items.any { it.kind == AgentTranscriptItem.Kind.AssistantText("hola") })
        assertTrue(state.items.any { (it.kind as? AgentTranscriptItem.Kind.ToolUse)?.name == "Write" })
        assertEquals(listOf("Write", "Bash"), permissionTools)
        assertEquals("00000000-0000-4000-8000-000000000000", state.sessionID)
        assertEquals(AgentStatus.Idle, state.status)
    }
}
