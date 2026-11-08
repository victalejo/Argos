package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.agent.AgentPermissionRequest
import com.iaportafolio.argos.core.agent.AgentResult
import com.iaportafolio.argos.core.agent.AgentTranscriptItem
import com.iaportafolio.argos.testing.SECRET_TOKEN
import com.iaportafolio.argos.ui.agents.AgentChatLoad
import com.iaportafolio.argos.ui.agents.AgentChatStatus
import com.iaportafolio.argos.ui.agents.AgentChatUiState
import com.iaportafolio.argos.ui.agents.AgentConnection
import com.iaportafolio.argos.ui.agents.AgentPermissionCard
import com.iaportafolio.argos.ui.agents.AgentTranscriptPresenter
import com.iaportafolio.argos.ui.agents.AgentTranscriptRow
import com.iaportafolio.argos.ui.agents.ReplayHold
import com.iaportafolio.argos.ui.agents.SecretRedactor
import com.iaportafolio.argos.ui.agents.TranscriptFollow
import com.iaportafolio.argos.ui.agents.TranscriptProjector
import com.iaportafolio.argos.ui.agents.agentFailureLogLine
import com.iaportafolio.argos.core.agent.AgentStatus
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.jupiter.api.Test
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class AgentTranscriptPresentationTest {

    private val plain = SecretRedactor()

    private fun row(kind: AgentTranscriptItem.Kind) = AgentTranscriptPresenter.row(AgentTranscriptItem(7, kind), plain)

    private fun json(text: String) = Json.parseToJsonElement(text)

    @Test
    fun `cada tipo de item da su fila con la clave estable`() {
        assertEquals(AgentTranscriptRow.User(7, "hola"), row(AgentTranscriptItem.Kind.UserText("hola")))
        assertEquals(AgentTranscriptRow.Assistant(7, "**sí**"), row(AgentTranscriptItem.Kind.AssistantText("**sí**")))
        assertEquals(AgentTranscriptRow.Thinking(7, "hmm"), row(AgentTranscriptItem.Kind.Thinking("hmm")))
        assertEquals(AgentTranscriptRow.ToolOutput(7, "boom", true), row(AgentTranscriptItem.Kind.ToolResult("boom", true)))
        assertEquals(AgentTranscriptRow.Failure(7, "fallo"), row(AgentTranscriptItem.Kind.Error("fallo")))
    }

    @Test
    fun `una herramienta se resume con AgentToolSummary y conserva todo su input`() {
        val tool = assertIs<AgentTranscriptRow.Tool>(
            row(AgentTranscriptItem.Kind.ToolUse("Bash", json("""{"command":"ls -la","timeout":5}"""))),
        )
        assertEquals("Bash", tool.name)
        assertEquals("ls -la", tool.summary)
        assertTrue("\"timeout\": 5" in tool.detail)
    }

    @Test
    fun `el fin de turno solo trae texto si es un error`() {
        val ok = AgentResult("success", isError = false, text = "resumen", totalCostUSD = 0.5)
        assertEquals(AgentTranscriptRow.TurnEnd(7, false, null, 0.5), row(AgentTranscriptItem.Kind.Result(ok)))
        val bad = AgentResult("error", isError = true, text = "no pude", totalCostUSD = null)
        assertEquals(AgentTranscriptRow.TurnEnd(7, true, "no pude", null), row(AgentTranscriptItem.Kind.Result(bad)))
    }

    @Test
    fun `una salida enorme se corta`() {
        val output = assertIs<AgentTranscriptRow.ToolOutput>(row(AgentTranscriptItem.Kind.ToolResult("x".repeat(50_000), false)))
        assertTrue(output.text.length < 20_100)
        assertTrue(output.text.endsWith("…"))
    }

    private fun request(tool: String, input: String, display: String? = null) =
        AgentPermissionRequest("r1", tool, display, json(input), null)

    @Test
    fun `la tarjeta de permiso dice qué herramienta y qué input`() {
        val card = AgentTranscriptPresenter.permissionCard(request("Bash", """{"command":"rm -rf build"}"""), plain)
        assertEquals("r1", card.requestId)
        assertEquals("Bash", card.tool)
        assertEquals("rm -rf build", card.summary)
        assertTrue("rm -rf build" in card.detail)
    }

    @Test
    fun `una herramienta sin resumen conocido no deja la tarjeta en blanco`() {
        val card = AgentTranscriptPresenter.permissionCard(request("mcp__x", """{"destino":"prod"}""", display = "Desplegar"), plain)
        assertEquals("Desplegar", card.tool)
        assertEquals("", card.summary)
        assertTrue("prod" in card.detail)
    }

    @Test
    fun `no se puede disfrazar lo que se aprueba con controles o marcas de dirección`() {
        assertEquals("a�b", AgentTranscriptPresenter.visibleText("a\u001Bb"))
        assertEquals("a�b", AgentTranscriptPresenter.visibleText("a‮b"))
        assertEquals("a�b", AgentTranscriptPresenter.visibleText("a\rb"))
        assertEquals("a\nb\tc ñ😀", AgentTranscriptPresenter.visibleText("a\nb\tc ñ😀"))
    }

    @Test
    fun `tapa el token conocido y lo que tiene su forma`() {
        assertEquals("x •••• y", SecretRedactor("mi-token").redact("x mi-token y"))
        assertEquals("x •••• y", SecretRedactor().redact("x $SECRET_TOKEN y"))
        assertEquals("sin secretos", SecretRedactor("mi-token").redact("sin secretos"))
    }

    @Test
    fun `una fila o tarjeta con el token no lo enseña`() {
        val redactor = SecretRedactor(SECRET_TOKEN)
        val rows = listOf(
            AgentTranscriptItem.Kind.UserText(SECRET_TOKEN),
            AgentTranscriptItem.Kind.AssistantText(SECRET_TOKEN),
            AgentTranscriptItem.Kind.Thinking(SECRET_TOKEN),
            AgentTranscriptItem.Kind.ToolUse("Bash", json("""{"command":"echo $SECRET_TOKEN"}""")),
            AgentTranscriptItem.Kind.ToolResult("TOKEN=$SECRET_TOKEN", true),
            AgentTranscriptItem.Kind.Result(AgentResult("error", true, SECRET_TOKEN, null)),
            AgentTranscriptItem.Kind.Error(SECRET_TOKEN),
        ).map { AgentTranscriptPresenter.row(AgentTranscriptItem(1, it), redactor) }
        rows.forEach { assertFalse(SECRET_TOKEN in it.toString(), it.toString()) }
        val card = AgentTranscriptPresenter.permissionCard(request("Bash", """{"command":"echo $SECRET_TOKEN"}"""), redactor)
        assertFalse(SECRET_TOKEN in card.toString())
    }

    @Test
    fun `el registro de un fallo solo lleva el tipo, nunca su mensaje`() {
        val line = agentFailureLogLine("No se pudo enviar", IOException("stderr con $SECRET_TOKEN y conversación"))
        assertEquals("No se pudo enviar (IOException)", line)
    }

    private fun item(id: Int, text: String = "m$id") = AgentTranscriptItem(id, AgentTranscriptItem.Kind.UserText(text))

    @Test
    fun `el proyector solo convierte lo nuevo y reutiliza las filas`() {
        var redactorRequests = 0
        val projector = TranscriptProjector {
            redactorRequests++
            plain
        }
        val first = projector.project(listOf(item(0), item(1)))
        assertEquals(listOf(0, 1), first.map { it.key })
        assertSame(first, projector.project(listOf(item(0), item(1))))
        assertEquals(1, redactorRequests)

        val second = projector.project(listOf(item(0), item(1), item(2)))
        assertEquals(listOf(0, 1, 2), second.map { it.key })
        assertSame(first[0], second[0])
    }

    @Test
    fun `el proyector vuelve a empezar si la conversación se vacía`() {
        val projector = TranscriptProjector { plain }
        projector.project(listOf(item(0), item(1)))
        assertEquals(emptyList(), projector.project(emptyList()))
        assertEquals(listOf("nuevo"), projector.project(listOf(item(0, "nuevo"))).map { (it as AgentTranscriptRow.User).text })
    }

    @Test
    fun `al releer el log se retienen las filas anteriores hasta alcanzarlas`() {
        val hold = ReplayHold()
        val old = listOf(AgentTranscriptRow.User(0, "a"), AgentTranscriptRow.User(1, "b"))
        assertEquals(old, hold.rowsToShow(old, replaying = false))

        assertTrue(hold.isReplaying(receivedBytes = 0, targetBytes = 100))
        assertEquals(old, hold.rowsToShow(emptyList(), replaying = true))
        assertEquals(old, hold.rowsToShow(old.take(1), replaying = true))

        assertFalse(hold.isReplaying(receivedBytes = 100, targetBytes = 100))
        assertEquals(old, hold.rowsToShow(old, replaying = false))
        // Sin relectura en curso manda el log (p. ej. se truncó).
        assertEquals(old.take(1), hold.rowsToShow(old.take(1), replaying = false))
    }

    @Test
    fun `seguir el final depende de la última fila visible`() {
        assertTrue(TranscriptFollow.isAtBottom(null, totalItems = 0, lastVisibleEnd = 0, viewportEnd = 800))
        assertFalse(TranscriptFollow.isAtBottom(null, totalItems = 3, lastVisibleEnd = 0, viewportEnd = 800))
        assertFalse(TranscriptFollow.isAtBottom(5, totalItems = 10, lastVisibleEnd = 700, viewportEnd = 800))
        assertTrue(TranscriptFollow.isAtBottom(9, totalItems = 10, lastVisibleEnd = 800, viewportEnd = 800))
        assertTrue(TranscriptFollow.isAtBottom(9, totalItems = 10, lastVisibleEnd = 840, viewportEnd = 800))
        assertFalse(TranscriptFollow.isAtBottom(9, totalItems = 10, lastVisibleEnd = 1_400, viewportEnd = 800))
    }

    private val ready = AgentChatUiState(load = AgentChatLoad.Ready, connection = AgentConnection.Connected)
    private val card = AgentPermissionCard("r1", "Bash", "ls", "{}")

    @Test
    fun `el estado visible resume agente, conexión y turno`() {
        assertEquals(AgentChatStatus.CONNECTING, AgentChatUiState().status)
        assertEquals(AgentChatStatus.IDLE, ready.status)
        assertEquals(AgentChatStatus.WORKING, ready.copy(conversationStatus = AgentStatus.Working).status)
        assertEquals(AgentChatStatus.ERROR, ready.copy(conversationStatus = AgentStatus.Failed("x")).status)
        assertEquals(AgentChatStatus.TERMINATED, ready.copy(conversationStatus = AgentStatus.Finished).status)
        assertEquals(AgentChatStatus.AWAITING_PERMISSION, ready.copy(permission = card).status)
        assertEquals(AgentChatStatus.CONNECTING, ready.copy(isReplaying = true, conversationStatus = AgentStatus.Working).status)
        // Muerto gana a todo: un turno cortado se quedaría en «trabajando» para siempre.
        assertEquals(AgentChatStatus.TERMINATED, ready.copy(isAlive = false, conversationStatus = AgentStatus.Working).status)
    }

    @Test
    fun `solo se puede decidir un permiso visible con el enganche vivo`() {
        assertEquals(card, ready.copy(permission = card).visiblePermission)
        assertNull(ready.copy(permission = card, isAlive = false).visiblePermission)
        assertNull(ready.copy(permission = card, isReplaying = true).visiblePermission)
        assertTrue(ready.copy(permission = card).canDecidePermission)
        assertFalse(ready.copy(permission = card, isResponding = true).canDecidePermission)
        assertFalse(ready.copy(permission = card, connection = AgentConnection.Retrying(1, 2)).canDecidePermission)
    }

    @Test
    fun `una herramienta sin input no rompe el resumen`() {
        val tool = assertIs<AgentTranscriptRow.Tool>(row(AgentTranscriptItem.Kind.ToolUse("Otra", JsonObject(emptyMap()))))
        assertEquals("", tool.summary)
        assertEquals("{}", tool.detail)
    }
}
