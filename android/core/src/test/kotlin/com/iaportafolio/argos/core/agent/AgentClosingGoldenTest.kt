package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.doctor.DoctorScript
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Lo último que añadió Swift a los agentes persistentes: «Detener» el turno (`interrupt`), el
 * listado con estado (`overview`) y los logs SEMBRADOS por el Mac. Goldens de
 * `GoldenCatalog.androidClosing()` con estas mismas entradas.
 */
class AgentClosingGoldenTest {

    private val id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)

    private fun assertGolden(name: String, actual: String) = assertEquals(golden(name), actual, "difiere de Swift: $name")

    private fun replay(log: String): AgentConversationState = SwiftText.lines(log).fold(AgentConversationState()) { state, line ->
        AgentProtocol.decode(line)?.let { AgentReducer.apply(it, state, echoesUserMessages = true) } ?: state
    }

    @Test
    fun `scripts y lineas iguales que en Swift`() {
        assertGolden("agent-interrupt", AgentProtocol.encodeInterrupt("argos-interrupt-$id"))
        assertGolden("overview", PersistentAgentOverview.command())
        assertGolden("doctor-script", DoctorScript.command)
    }

    @Test
    fun `un log sembrado se ve entero y quieto`() {
        val state = replay(golden("seed-log"))
        val kinds = state.items.map { it.kind }
        assertEquals(AgentTranscriptItem.Kind.UserText("revisa el código"), kinds.first())
        assertTrue(kinds.any { it is AgentTranscriptItem.Kind.Thinking })
        assertTrue(kinds.any { it is AgentTranscriptItem.Kind.ToolUse && it.name == "Read" })
        assertTrue(kinds.any { it is AgentTranscriptItem.Kind.ToolResult && it.text.contains("línea 2") })
        assertTrue(kinds.any { it == AgentTranscriptItem.Kind.AssistantText("Todo bien.") })
        assertEquals(AgentStatus.Idle, state.status)
        // Acaba en un `result` real de la conversación: ese sí es «terminó».
        assertEquals(AgentAttention.Finished("Todo bien.", isError = false), AgentAttention.evaluate(golden("seed-log")))
    }

    @Test
    fun `el result que cierra un log sembrado no avisa de termino`() {
        val log = golden("seed-log-open")
        assertTrue(log.contains(AgentTranscriptSeed.CLOSING_SUBTYPE))
        val state = replay(log)
        assertEquals(AgentTranscriptItem.Kind.UserText("hola"), state.items.first().kind)
        assertEquals(AgentStatus.Idle, state.status)
        val attention = AgentAttention.evaluate(log)
        assertIs<AgentAttention.Finished>(attention)
        assertTrue(attention.seeded)
        assertNull(attention.notification("t"))
        // Un agente sembrado recién creado: sin aviso, pero visto.
        val snapshot = AgentLogSnapshot(id, true, log.length.toLong() + 1, "t", Instant.ofEpochSecond(1_000), log)
        val plan = AgentAttentionPlanner.notices(listOf(snapshot), emptyMap(), Instant.ofEpochSecond(1_060))
        assertTrue(plan.notices.isEmpty())
        assertEquals(snapshot.logBytes, plan.seen[id])
        // Igual con la línea cortada (lectura tolerante del final del log).
        val cut = """{"is_error":false,"subtype":"argos_seed","type":"result""""
        assertIs<AgentAttention.Finished>(AgentAttention.evaluate(cut)).also { assertTrue(it.seeded) }
    }

    @Test
    fun `el listado con estado distingue trabajando, permiso, esperando, reposo y detenido`() {
        val meta = PersistentAgentMeta("/srv/web", "web", Instant.ofEpochSecond(1_800_000_000))
        val metaB64 = SwiftText.encodeBase64(PersistentAgentMeta.encode(meta).toByteArray(Charsets.UTF_8))
        val slept = SwiftText.encodeBase64(
            PersistentAgentMeta.encode(meta.copy(hibernatedAt = Instant.ofEpochSecond(1_800_000_100))).toByteArray(Charsets.UTF_8),
        )
        fun tail(text: String) = SwiftText.encodeBase64(text.toByteArray(Charsets.UTF_8))
        val permission = """{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"""
        val result = """{"type":"result","subtype":"success","is_error":false,"result":"ok"}"""
        val ids = (1..5).map { "0000000$it-0000-0000-0000-000000000000" }
        val output = listOf(
            "${ids[0]}|1|120|5|$metaB64|${tail("""{"type":"assistant","message":{"content":[]}}""")}",
            "${ids[1]}|1|300|60|$metaB64|${tail(permission)}",
            "${ids[2]}|1|400|3600|$metaB64|${tail(result)}",
            "${ids[3]}|0|400|-3|$slept|",
            "${ids[4]}|0|400|x|$metaB64|",
            "basura",
        ).joinToString("\n")
        val agents = PersistentAgentOverview.parse(output).associateBy { it.id }
        assertEquals(5, agents.size)
        assertEquals(PersistentAgentActivity.Working, agents.getValue(ids[0]).activity)
        assertEquals(PersistentAgentActivity.WaitingPermission("Bash"), agents.getValue(ids[1]).activity)
        assertEquals(PersistentAgentActivity.Idle, agents.getValue(ids[2]).activity)
        assertEquals(PersistentAgentActivity.Asleep, agents.getValue(ids[3]).activity)
        assertEquals(0L, agents.getValue(ids[3]).idleSeconds)
        assertEquals(PersistentAgentActivity.Stopped, agents.getValue(ids[4]).activity)
        assertNull(agents.getValue(ids[4]).idleSeconds)
        assertEquals(Instant.ofEpochSecond(940), agents.getValue(ids[1]).lastActivity(Instant.ofEpochSecond(1_000)))
    }

    @Test
    fun `carpetas comparables sin barra final`() {
        assertTrue(AgentFolderMatch.same("/srv/web/", "/srv/web"))
        assertTrue(AgentFolderMatch.same(" /srv/web//", "/srv/web"))
        assertEquals("/", AgentFolderMatch.normalized("/"))
    }
}
