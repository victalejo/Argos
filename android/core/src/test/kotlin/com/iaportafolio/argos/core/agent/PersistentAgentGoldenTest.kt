package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.RemoteTimeout
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * Paridad BYTE A BYTE con Swift de lo que endurece a los agentes persistentes: hibernación,
 * parada, envío por stdin, rotación, inventario, guardia de memoria y tope de resultados. Los
 * goldens los genera `ArgosTests/GoldenCatalog.swift` con EXACTAMENTE estas entradas
 * (`scripts/regenerate-swift-goldens.sh`).
 */
class PersistentAgentGoldenTest {

    private val id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private val other = "11111111-2222-3333-4444-555555555555"
    private val meta = PersistentAgentMeta("~/proyectos/tienda", "tienda \"ñ\" a/b", Instant.ofEpochMilli(1_800_000_000_750))
    private val invocation = ClaudeAgentCommand.persistent("/usr/bin/claude", id, resume = false)

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)

    private fun assertGolden(name: String, actual: String) = assertEquals(golden(name), actual, "difiere de Swift: $name")

    @Test
    fun `lanzador con y sin vigilante de reposo`() {
        assertGolden("launch", PersistentAgentScript.launch(id, meta, invocation))
        assertGolden("launch-no-hibernation", PersistentAgentScript.launch(id, meta, invocation, PersistentAgentHibernation.ofHours(0)))
        assertGolden("launch-hibernation-1h", PersistentAgentScript.launch(id, meta, invocation, PersistentAgentHibernation.ofHours(1)))
        val hibernated = meta.copy(permissionMode = "plan", hibernatedAt = Instant.ofEpochSecond(1_800_003_600))
        assertGolden("meta-json-hibernated", PersistentAgentMeta.encode(hibernated))
    }

    @Test
    fun `envio por stdin, parada, reposo y final de err log`() {
        assertGolden("send-stdin", PersistentAgentScript.sendViaStdin(id, 70_001))
        assertGolden("send-stdin-answered", PersistentAgentScript.sendViaStdin(id, 20_000, "r\"1/x", timeoutSeconds = 2))
        assertGolden("stop-grace", PersistentAgentScript.stop(id, delete = false, graceSeconds = 1))
        assertGolden("hibernate", PersistentAgentScript.hibernate(id, 3600))
        assertGolden("error-tail", PersistentAgentScript.errorTail(id))
    }

    @Test
    fun `trozos de shell`() {
        val dir = PersistentAgentScript.directory(id)
        assertGolden("watchdog", PersistentAgentShell.watchdog(id, 14_400, 300))
        assertGolden("rotate-log", PersistentAgentShell.rotateOutputLog(dir))
        assertGolden("rotate-log-small", PersistentAgentShell.rotateOutputLog(dir, 200_000, 100_000))
        assertGolden("trim-err-log", PersistentAgentShell.trimErrorLog(dir))
        assertGolden("mark-hibernated", PersistentAgentShell.markHibernated(dir))
        assertGolden("terminate-process", PersistentAgentShell.terminateProcess(id, 3))
    }

    @Test
    fun `inventario del servidor y sus acciones`() {
        assertGolden("inventory", ServerAgentInventory.script())
        assertGolden("inventory-stop", ServerAgentInventory.stopPersistent(listOf(id, "no-es-un-uuid", other)))
        assertGolden("inventory-hibernate", ServerAgentInventory.hibernate(listOf(id, other), 7200))
        assertGolden("inventory-stop-panel", ServerAgentInventory.stopPanel(listOf(4242 to other.uppercase(), 1 to id)))
        assertGolden("inventory-stop-panel-sessions", ServerAgentInventory.stopPanelSessions(listOf(other, "x")))
    }

    @Test
    fun `textos de la interfaz y topes`() {
        assertGolden("hibernation-warning", PersistentAgentHibernation.BACKGROUND_WORK_WARNING)
        val assessments = listOf(
            AgentLaunchGuard.assess(512_000, 0),
            AgentLaunchGuard.assess(850, 0),
            AgentLaunchGuard.assess(2_000_000, 7),
            AgentLaunchGuard.assess(null, 6),
        ).joinToString("\n") {
            when (it) {
                AgentLaunchGuard.Assessment.Ok -> "ok"
                is AgentLaunchGuard.Assessment.Warning -> "${it.title}|${it.message}"
            }
        }
        assertGolden("launch-guard", assessments)
        assertGolden("tool-result-clip", AgentTranscriptLimits.clip("é👍🏽a".repeat(6_000)))
    }

    @Test
    fun `plazo en el servidor para los sondeos`() {
        assertGolden("remote-timeout", RemoteTimeout.wrap("tmux list-sessions -F '#{session_name}' | grep \"\$x\""))
        assertGolden("remote-timeout-short", RemoteTimeout.wrap("true", seconds = 0))
    }
}
