package com.iaportafolio.argos.core.agent

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Paridad con `PersistentAgentConversationTests` y `AgentAttentionTests` de
 * `ArgosTests/PersistentAgentTests.swift` (solo lo puro: sin sesión ni mock SSH).
 */
class PersistentAgentConversationTest {

    private fun decode(line: String): AgentStreamEvent = assertNotNull(AgentProtocol.decode(line))

    @Test
    fun `los prompts reenviados son burbujas del usuario`() {
        val user = decode("""{"type":"user","message":{"role":"user","content":"hola"}}""")
        val state = AgentReducer.apply(user, AgentConversationState(), echoesUserMessages = true)
        assertEquals(listOf<AgentTranscriptItem.Kind>(AgentTranscriptItem.Kind.UserText("hola")), state.items.map { it.kind })
        assertEquals(AgentStatus.Working, state.status)

        // Sin reenvío (modo clásico del Mac) el texto de un evento user se ignora.
        assertTrue(AgentReducer.apply(user, AgentConversationState()).items.isEmpty())
    }

    @Test
    fun `la marca de respondido cierra el permiso al releer`() {
        val request = """{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"""
        var state = AgentReducer.apply(decode(request), AgentConversationState(), echoesUserMessages = true)
        assertEquals("r1", state.pendingPermission?.id)
        // Un control_response cualquiera en el log NO cierra el permiso: solo la marca de Argos.
        val answer = AgentProtocol.encodePermissionResponse("r1", AgentPermissionDecision.Allow(EmptyJsonObject))
        state = AgentReducer.apply(decode(answer), state, echoesUserMessages = true)
        assertEquals("r1", state.pendingPermission?.id)
        val marker = """{"request_id":"r1","type":"argos_permission_answered"}"""
        state = AgentReducer.apply(decode(marker), state, echoesUserMessages = true)
        assertNull(state.pendingPermission)
    }

    @Test
    fun `los prompts de subagentes y sinteticos no se hacen pasar por el usuario`() {
        val sub = """{"type":"user","parent_tool_use_id":"toolu_1","message":{"content":"instrucciones al subagente"}}"""
        val meta = """{"type":"user","isMeta":true,"message":{"content":"<system>…</system>"}}"""
        val top = """{"type":"user","parent_tool_use_id":null,"message":{"content":"hola"}}"""
        val state = listOf(sub, meta, top).fold(AgentConversationState()) { current, line ->
            AgentReducer.apply(decode(line), current, echoesUserMessages = true)
        }
        assertEquals(listOf<AgentTranscriptItem.Kind>(AgentTranscriptItem.Kind.UserText("hola")), state.items.map { it.kind })
    }

    // AgentAttentionTests

    private val permiso = """{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"""
    private val respondido = """{"type":"argos_permission_answered","request_id":"r1"}"""
    private val resultado = """{"type":"result","subtype":"success","is_error":false,"result":"Listo: 3 tests verdes."}"""
    private val prompt = """{"type":"user","message":{"content":"otra cosa"}}"""

    @Test
    fun `detecta permiso pendiente y terminado`() {
        assertEquals(AgentAttention.NeedsPermission("Bash"), AgentAttention.evaluate(permiso))
        assertEquals(AgentAttention.None, AgentAttention.evaluate(listOf(permiso, respondido).joinToString("\n")))
        assertEquals(
            AgentAttention.Finished("Listo: 3 tests verdes.", false),
            AgentAttention.evaluate(listOf(permiso, respondido, resultado).joinToString("\n")),
        )
        // Tras un resultado, un prompt nuevo significa que vuelve a trabajar.
        assertEquals(AgentAttention.None, AgentAttention.evaluate(listOf(resultado, prompt).joinToString("\n")))
        // La primera línea cortada (trozo del final del log) se ignora.
        assertNotEquals(AgentAttention.None, AgentAttention.evaluate("a\":1}\n$resultado"))
    }

    @Test
    fun `solo avisa de lo nuevo y una vez`() {
        val viejo = Instant.ofEpochSecond(1)
        val ahora = Instant.ofEpochSecond(1_000_000)
        fun snap(bytes: Long, created: Instant = viejo, tail: String) =
            AgentLogSnapshot("6a55640d-ac70-41ab-8426-6eb72d4fb5eb", true, bytes, "tienda", created, tail)

        // Agente viejo nunca visto: solo referencia.
        var r = AgentAttentionPlanner.notices(listOf(snap(100, tail = resultado)), emptyMap(), ahora)
        assertTrue(r.notices.isEmpty())
        // Creció y terminó: aviso.
        r = AgentAttentionPlanner.notices(listOf(snap(200, tail = resultado)), r.seen, ahora)
        assertEquals("tienda: Claude terminó", r.notices.firstOrNull()?.title)
        assertEquals("Listo: 3 tests verdes.", r.notices.firstOrNull()?.body)
        // Sin cambios: no se repite.
        r = AgentAttentionPlanner.notices(listOf(snap(200, tail = resultado)), r.seen, ahora)
        assertTrue(r.notices.isEmpty())
        // Agente reciente nunca visto que pide permiso: aviso.
        val nuevo = AgentAttentionPlanner.notices(listOf(snap(50, created = ahora, tail = permiso)), emptyMap(), ahora)
        assertEquals("tienda: Claude espera tu permiso", nuevo.notices.firstOrNull()?.title)
        // Los agentes que desaparecen se olvidan.
        assertTrue(AgentAttentionPlanner.notices(emptyList(), r.seen, ahora).seen.isEmpty())
    }

    @Test
    fun `parsea las instantaneas`() {
        val meta = PersistentAgentMeta("/srv", "srv", Instant.ofEpochSecond(5))
        val metaB64 = SwiftText.encodeBase64(PersistentAgentMeta.encode(meta).toByteArray())
        val id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
        val output = "$id|1|42|$metaB64|${SwiftText.encodeBase64(resultado.toByteArray())}\nbasura|x"
        val snapshots = PersistentAgentScript.parseSnapshots(output)
        assertEquals(1, snapshots.size)
        assertTrue(snapshots[0].logBytes == 42L && snapshots[0].title == "srv" && snapshots[0].tail == resultado)
    }

    @Test
    fun `el cuerpo del aviso se corta a 180 caracteres visibles y hay textos por defecto`() {
        val body = AgentAttention.Finished("👍🏽".repeat(200), false).notification("t")?.body
        assertEquals("👍🏽".repeat(180), body)
        assertEquals("Terminó con un error.", AgentAttention.Finished(null, true).notification("t")?.body)
        assertEquals("t: Claude terminó con error", AgentAttention.Finished(null, true).notification("t")?.title)
        assertNull(AgentAttention.None.notification("t"))
    }
}
