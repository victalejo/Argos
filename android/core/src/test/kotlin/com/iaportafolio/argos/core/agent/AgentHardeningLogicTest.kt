package com.iaportafolio.argos.core.agent

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Port de `ArgosTests/AgentHardeningLogicTests.swift` (lógica pura del endurecimiento). */
class AgentHardeningLogicTest {

    private val id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private val panelID = "11111111-2222-3333-4444-555555555555"

    // MARK: Avisos tolerantes a líneas recortadas

    private val cutPermission: String
        get() {
            val line = """{"type":"control_request","request_id":"r7","request":{"subtype":"can_use_tool","tool_name":"Write",""" +
                """"input":{"content":"""" + "x".repeat(70_000) + """"}}}"""
            return line.take(400)
        }

    @Test
    fun `un permiso recortado se detecta y la marca lo cierra`() {
        assertEquals(AgentAttention.NeedsPermission("Write"), AgentAttention.evaluate(cutPermission))
        val answered = """{"request_id":"r7","type":"argos_permission_answered"}"""
        assertEquals(AgentAttention.None, AgentAttention.evaluate(cutPermission + "\n" + answered))
    }

    @Test
    fun `un permiso ilegible no se da por visto`() {
        val unreadable = """{"type":"control_request","request":{"subtype":"can_use_tool","input":{"content":"xxxx"""
        assertEquals(AgentAttention.Undetermined, AgentAttention.evaluate(unreadable))
        assertEquals(AgentAttention.Undetermined, AgentAttention.evaluate("zzzz\nyyyy"))
        assertEquals(AgentAttention.None, AgentAttention.evaluate(""))

        val snapshot = AgentLogSnapshot(id, true, 500, "t", Instant.now(), unreadable)
        val plan = AgentAttentionPlanner.notices(listOf(snapshot), mapOf(id to 100L))
        assertTrue(plan.notices.isEmpty())
        assertEquals(100L, plan.seen[id]) // sin avanzar: el próximo refresco lo reintenta
    }

    @Test
    fun `un resultado recortado se resume igual`() {
        val cut = ("""{"type":"result","subtype":"success","is_error":false,"result":"Hecho: """ + "a".repeat(2_000)).take(400)
        val finished = assertIs<AgentAttention.Finished>(AgentAttention.evaluate(cut))
        assertFalse(finished.isError)
    }

    @Test
    fun `un prompt recortado vuelve a trabajar y un resultado de herramienta no`() {
        val finished = """{"type":"result","subtype":"success","is_error":false,"result":"ok"}"""
        val prompt = ("""{"type":"user","message":{"role":"user","content":"""" + "p".repeat(900)).take(400)
        assertEquals(AgentAttention.None, AgentAttention.evaluate(finished + "\n" + prompt))
        val toolResult = ("""{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"""" +
            "r".repeat(900)).take(400)
        assertNotEquals(AgentAttention.None, AgentAttention.evaluate(finished + "\n" + toolResult))
    }

    @Test
    fun `extrae cadenas con escapes`() {
        assertEquals("x\"y", AgentLogLineSummary.firstString("\"a\":", """{"a": "x\"y"}"""))
        assertNull(AgentLogLineSummary.firstString("\"a\":", """{"a":"sin cerrar"""))
        assertNull(AgentLogLineSummary.firstString("\"b\":", """{"a":"x"}"""))
    }

    @Test
    fun `el script de avisos recorta las lineas y mide el tamaño absoluto`() {
        val script = PersistentAgentScript.snapshots()
        assertTrue(script.contains("tail -n ${PersistentAgentScript.ATTENTION_TAIL_LINES}"))
        assertTrue(script.contains("cut -c 1-${PersistentAgentScript.ATTENTION_LINE_BYTES}"))
        assertTrue(script.contains("log.base"))
        assertFalse(script.contains("tail -c 16384"))
    }

    // MARK: Tope de resultados

    @Test
    fun `los resultados enormes se recortan con indicacion`() {
        val big = "a".repeat(12_000) + "b".repeat(50_000) + "c".repeat(2_000)
        val clipped = AgentTranscriptLimits.clip(big)
        assertTrue(clipped.length < AgentTranscriptLimits.MAX_TOOL_RESULT_CHARACTERS + 200)
        assertTrue(clipped.startsWith("a".repeat(12_000)))
        assertTrue(clipped.endsWith("c".repeat(2_000)))
        assertTrue(clipped.contains("recortado: 50000 caracteres omitidos"))
        assertEquals("corto", AgentTranscriptLimits.clip("corto"))

        val line = """{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"""" + big + """"}]}}"""
        val state = AgentReducer.apply(requireNotNull(AgentProtocol.decode(line)), AgentConversationState())
        val kind = assertIs<AgentTranscriptItem.Kind.ToolResult>(state.items.first().kind)
        assertEquals(clipped, kind.text)
    }

    @Test
    fun `cuenta grafemas como Swift al recortar`() {
        // 16 001 emojis con tono de piel: 32 002 unidades UTF-16 pero 16 001 caracteres.
        val emoji = "👍🏽".repeat(16_001)
        val clipped = AgentTranscriptLimits.clip(emoji)
        assertTrue(clipped.contains("recortado: 2001 caracteres omitidos"))
        assertEquals("👍🏽".repeat(16_000), AgentTranscriptLimits.clip("👍🏽".repeat(16_000)))
    }

    // MARK: Guardia, reintentos y reposo

    @Test
    fun `avisa con poca memoria o muchos agentes`() {
        assertEquals(AgentLaunchGuard.Assessment.Ok, AgentLaunchGuard.assess(4_000_000, 2))
        assertEquals(AgentLaunchGuard.Assessment.Ok, AgentLaunchGuard.assess(null, 0))
        val memory = assertIs<AgentLaunchGuard.Assessment.Warning>(AgentLaunchGuard.assess(500_000, 0))
        assertTrue(memory.title.contains("memoria"))
        val many = assertIs<AgentLaunchGuard.Assessment.Warning>(AgentLaunchGuard.assess(8_000_000, 6))
        assertTrue(many.title.contains("6"))
    }

    @Test
    fun `espera entre reintentos`() {
        assertEquals(listOf(1, 2, 4, 8, 16, 30, 30), (1..7).map(AgentReconnectPolicy::delaySeconds))
        assertEquals(1, AgentReconnectPolicy.delaySeconds(0))
    }

    @Test
    fun `plazo de reposo`() {
        assertEquals(PersistentAgentHibernation.DEFAULT_IDLE_HOURS, PersistentAgentHibernation.sanitizedHours(null))
        assertEquals(PersistentAgentHibernation.DEFAULT_IDLE_HOURS, PersistentAgentHibernation.sanitizedHours(13))
        assertEquals(0, PersistentAgentHibernation.sanitizedHours(0))
        assertFalse(PersistentAgentHibernation.ofHours(0).isEnabled)
        assertEquals(8 * 3600, PersistentAgentHibernation.ofHours(8).idleSeconds)
        assertEquals(listOf("Nunca", "1 hora", "2 horas"), listOf(0, 1, 2).map(PersistentAgentHibernation::title))
    }

    // MARK: Inventario

    private fun panelArgs(sessionFlag: String = "--session-id", extra: String = ""): String =
        "/home/u/.local/bin/claude -p --input-format stream-json --output-format stream-json --verbose " +
            "--permission-prompt-tool stdio --permission-mode default $sessionFlag $panelID$extra"

    @Test
    fun `reconoce solo las conversaciones del panel`() {
        assertEquals(panelID, ServerAgentInventory.panelSessionID(panelArgs()))
        assertEquals(panelID, ServerAgentInventory.panelSessionID(panelArgs("--resume")))
        assertNull(ServerAgentInventory.panelSessionID(panelArgs(extra = " --replay-user-messages")))
        assertNull(ServerAgentInventory.panelSessionID("claude --session-id $panelID"))
        assertNull(ServerAgentInventory.panelSessionID("grep -- " + panelArgs()))
        assertNull(ServerAgentInventory.panelSessionID("sh -c " + panelArgs()))
        assertNull(ServerAgentInventory.panelSessionID(panelArgs().replace(panelID, "no-uuid")))
    }

    @Test
    fun `parsea persistentes, panel y memoria`() {
        val meta = SwiftText.encodeBase64(PersistentAgentMeta.encode(PersistentAgentMeta("/srv/a", "a", Instant.ofEpochSecond(5))).toByteArray())
        val output = listOf(
            "P|$id|1|512000|7200|4096|0|$meta",
            "P|${UUID.randomUUID().toString().uppercase()}|0|0|99|10|0|$meta",
            "P|no-uuid|1|1|1|1|0|$meta",
            "M|4321|480000|${panelArgs()}",
            "M|4322|1000|vim notas.txt --input-format stream-json",
            "MEM|2048000",
            "basura",
        ).joinToString("\n")
        val inventory = ServerAgentInventory.parse(output)
        assertEquals(3, inventory.agents.size)
        assertEquals(2_048_000L, inventory.freeMemoryKB)
        assertEquals(2, inventory.liveAgents.size)
        assertEquals(992_000L, inventory.liveResidentKB)
        assertEquals(512_000L, inventory.agents.first().residentKB) // vivos primero, por memoria
        val panel = inventory.agents.first { it.kind is ServerAgentProcess.Kind.Panel }
        assertEquals(ServerAgentProcess.Kind.Panel(4321), panel.kind)
        assertEquals(panelID, panel.sessionID)
        assertNull(panel.idleSeconds)
        assertEquals(listOf(id), inventory.hibernationCandidates(3600).map { it.sessionID })
        assertTrue(inventory.hibernationCandidates(10_000).isEmpty())
    }

    @Test
    fun `no hiberna los que esperan permiso`() {
        val meta = SwiftText.encodeBase64(PersistentAgentMeta.encode(PersistentAgentMeta("/srv", "s", Instant.now())).toByteArray())
        val inventory = ServerAgentInventory.parse("P|$id|1|1|99999|1|1|$meta")
        assertEquals(true, inventory.agents.firstOrNull()?.hasPendingPermission)
        assertTrue(inventory.hibernationCandidates(60).isEmpty())
    }

    @Test
    fun `las acciones comprueban antes de matar`() {
        val stop = ServerAgentInventory.stopPanel(listOf(4321 to panelID, 1 to panelID, 9 to "x"))
        assertTrue(stop.contains("4321:$panelID"))
        assertTrue(stop.contains("pm()"))
        assertTrue(stop.contains("kill -s KILL"))
        assertFalse(stop.contains(" 1:"))
        assertFalse(stop.contains("9:x"))
        assertEquals("true", ServerAgentInventory.stopPanel(emptyList()))
        assertEquals("true", ServerAgentInventory.stopPanelSessions(listOf("no-uuid")))
        val hibernate = ServerAgentInventory.hibernate(listOf(id, "../x"), 3600)
        assertTrue(hibernate.contains("hibernatedAt") && hibernate.contains("-ge 3600"))
        assertFalse(hibernate.contains("../x"))
        assertFalse(ServerAgentInventory.stopPersistent(listOf("../x")).contains("rm -rf"))
        val both = ServerAgentInventory.stopPersistent(listOf(id, panelID))
        assertEquals(3, both.split(ServerAgentInventory.FAILED_MARKER).size)
        assertEquals(listOf(id), ServerAgentInventory.failures("x\n${ServerAgentInventory.FAILED_MARKER} $id\n"))
        assertFalse(ServerAgentInventory.script().contains("stream-json"))
    }

    // MARK: Protocolo

    @Test
    fun `el buffer cuenta los bytes de cada linea`() {
        val first = NdjsonLineBuffer().appendCountingBytes("ñ1\n{\"a\"".toByteArray())
        assertEquals(listOf(4), first.lines.map { it.byteCount })
        assertEquals("ñ1", first.lines.first().text)
        val second = first.buffer.appendCountingBytes(byteArrayOf(0xFF.toByte(), 0x0A) + ":1}\n".toByteArray())
        assertEquals(listOf(6, 4), second.lines.map { it.byteCount })
        assertNull(second.lines.first().text) // no es UTF-8, pero sus bytes cuentan
    }

    @Test
    fun `la cabecera del enganche se reconoce`() {
        assertEquals(PersistentAgentScript.LogBase(100, 5), PersistentAgentScript.parseLogBase("""{"type":"argos_log_base","base":100,"from":5}"""))
        assertNull(PersistentAgentScript.parseLogBase("""{"type":"assistant"}"""))
        assertNull(PersistentAgentScript.parseLogBase("""{"type":"argos_log_base","base":-1,"from":5}"""))
        assertNull(PersistentAgentScript.parseLogBase("""{"type":"argos_log_base","base":"1","from":5}"""))
    }

    @Test
    fun `el parser del enganche ignora el ruido del perfil y corta tras la rotacion`() {
        val parser = AgentAttachStreamParser()
        assertEquals(AgentAttachStreamParser.Line.Noise, parser.classify("Bienvenido a Ubuntu"))
        assertEquals(AgentAttachStreamParser.Line.Header(10, 3), parser.classify("""{"type":"argos_log_base","base":10,"from":3}"""))
        assertEquals(AgentAttachStreamParser.Line.Data, parser.classify("""{"type":"assistant"}"""))
        assertEquals(AgentAttachStreamParser.Line.Data, parser.classify(null))
        assertEquals(AgentAttachStreamParser.Line.Rotated, parser.classify(PersistentAgentShell.ROTATED_LINE))
        assertEquals(AgentAttachStreamParser.Line.Noise, parser.classify("""{"type":"assistant"}"""))
        // Sin cabecera, el primer JSON empieza los datos.
        assertEquals(AgentAttachStreamParser.Line.Data, AgentAttachStreamParser().classify("""{"type":"user"}"""))
    }

    @Test
    fun `respuestas del lanzador`() {
        assertTrue(PersistentAgentScript.isLaunchReply("4242"))
        assertTrue(PersistentAgentScript.isLaunchReply(PersistentAgentScript.ALIVE_REPLY))
        assertTrue(PersistentAgentScript.isLaunchReply("${PersistentAgentScript.FAILED_REPLY} eA=="))
        assertFalse(PersistentAgentScript.isLaunchReply("Bienvenido"))
        PersistentAgentScript.parseLaunchReply("4242")
        PersistentAgentScript.parseLaunchReply(PersistentAgentScript.ALIVE_REPLY)
        assertEquals(
            PersistentAgentError.BUSY,
            assertFailsWith<PersistentAgentException> { PersistentAgentScript.parseLaunchReply(PersistentAgentScript.BUSY_REPLY) }.error,
        )
        val failed = assertFailsWith<PersistentAgentException> { PersistentAgentScript.parseLaunchReply(PersistentAgentScript.FAILED_REPLY) }
        assertEquals(PersistentAgentError.LAUNCH_FAILED.message, failed.message)
        assertFailsWith<AgentExecException> { PersistentAgentScript.parseLaunchReply("sh: error") }
    }

    @Test
    fun `meta json compatible hacia atras y con reposo`() {
        val old = """{"createdAt":"2027-01-15T08:00:00Z","title":"t","workingDirectory":"/srv"}"""
        val meta = requireNotNull(PersistentAgentMeta.decode(old))
        assertFalse(meta.isHibernated)
        // Lo que escribe `markHibernated` (sed sobre el JSON con sangría).
        val marked = PersistentAgentMeta.encode(meta).trimEnd().removeSuffix("}") + ",\"hibernatedAt\":\"2027-01-15T12:00:00Z\"}"
        assertEquals(Instant.parse("2027-01-15T12:00:00Z"), PersistentAgentMeta.decode(marked)?.hibernatedAt)
        assertNull(PersistentAgentMeta.decode(old.replace("}", ",\"hibernatedAt\":\"ayer\"}")))
        assertFalse(requireNotNull(PersistentAgentMeta.decode(old.replace("}", ",\"hibernatedAt\":null}"))).isHibernated)
    }

    // MARK: Intercambio por stdin

    /** Canal exec falso: responde con [reply] (troceado) y registra lo recibido por stdin. */
    private class FakeExec(
        private val reply: List<String>,
        private val hangs: Boolean = false,
        private val endsAfterReply: Boolean = false,
    ) : AgentExecStreaming {
        val received = StringBuilder()
        var stdinClosed = false

        override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
            reply.forEach { output(it.toByteArray()) }
            if (hangs) kotlinx.coroutines.awaitCancellation()
            if (endsAfterReply) return // EOF del proceso remoto
            stdin.collect { received.append(it.toString(Charsets.UTF_8)) }
            stdinClosed = true
        }

        override suspend fun claudeAuthStatus(): ClaudeAuthStatus? = null
    }

    @Test
    fun `la primera linea aceptada salta el ruido del perfil`() = runBlocking {
        val exec = FakeExec(listOf("motd\nARGOS_SE", "NT\nmas\n"))
        val line = AgentStdinExchange.firstLine(exec, "x", "hola\n".toByteArray(), accept = { it.startsWith("ARGOS_") })
        assertEquals("ARGOS_SENT", line)
        assertTrue(exec.stdinClosed)
        assertEquals("hola\n", exec.received.toString())
    }

    @Test
    fun `sin respuesta a tiempo se lanza el plazo`() = runBlocking<Unit> {
        val exec = FakeExec(listOf("ruido\n"), hangs = true)
        assertFailsWith<AgentExchangeTimeoutException> {
            AgentStdinExchange.firstLine(exec, "x", ByteArray(0), timeoutMillis = 200, accept = { it == "ok" })
        }
    }

    @Test
    fun `una respuesta sin salto de linea final tambien vale`() = runBlocking {
        val exec = FakeExec(listOf("ARGOS_AGENT_ALIVE"), endsAfterReply = true)
        assertEquals("ARGOS_AGENT_ALIVE", AgentStdinExchange.firstLine(exec, "x", ByteArray(0), accept = PersistentAgentScript::isLaunchReply))
    }
}
