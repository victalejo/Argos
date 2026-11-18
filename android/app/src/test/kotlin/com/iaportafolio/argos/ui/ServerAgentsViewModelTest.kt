package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.PersistentAgentMeta
import com.iaportafolio.argos.core.agent.ServerAgentInventory
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.testing.AGENT_1
import com.iaportafolio.argos.testing.AGENT_2
import com.iaportafolio.argos.testing.FakeAgentService
import com.iaportafolio.argos.testing.InMemoryAgentPermissionBackend
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.networkDown
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.agents.ServerAgentsFormat
import com.iaportafolio.argos.ui.agents.ServerAgentsLoad
import com.iaportafolio.argos.ui.agents.ServerAgentsViewModel
import com.iaportafolio.argos.ui.common.UiText
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.time.Instant
import java.util.Base64
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** «Agentes en este servidor» (paridad con `ServerAgentsView` de iOS). */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ServerAgentsViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val ssh = FakeAgentService()
    private val settings = AgentPermissionStore(InMemoryAgentPermissionBackend())
    private val panelID = "99999999-2222-3333-4444-555555555555"

    private fun viewModel() =
        ServerAgentsViewModel("S1", InMemoryServerRepository(listOf(server())), SingleServiceProvider(ssh), settings, main.dispatcher)

    private fun meta(title: String): String = Base64.getEncoder()
        .encodeToString(PersistentAgentMeta.encode(PersistentAgentMeta("/srv/a/b/c", title, Instant.ofEpochSecond(5))).toByteArray())

    private val inventory = listOf(
        "P|$AGENT_1|1|512000|20000|10|0|${meta("quieto")}",
        "P|$AGENT_2|1|256000|60|10|0|${meta("activo")}",
        "M|4321|100000|/usr/bin/claude -p --input-format stream-json --output-format stream-json " +
            "--permission-prompt-tool stdio --session-id $panelID",
        "MEM|3000000",
    ).joinToString("\n")

    @Test
    fun `lista los agentes con memoria y solo propone hibernar los inactivos`() = runTest(main.dispatcher) {
        ssh.inventoryOutput = inventory
        val vm = viewModel()
        advanceUntilIdle()
        val loaded = assertIs<ServerAgentsLoad.Loaded>(vm.state.value.load)
        assertEquals(3, loaded.inventory.liveAgents.size)
        assertEquals(listOf(AGENT_1), vm.state.value.candidates.map { it.sessionID }) // 4 h por defecto

        vm.hibernateIdle()
        advanceUntilIdle()
        assertEquals(ServerAgentInventory.hibernate(listOf(AGENT_1), 4 * 3600), ssh.scripts.single())
    }

    @Test
    fun `detener todos para persistentes y conversaciones del panel tras confirmar`() = runTest(main.dispatcher) {
        ssh.inventoryOutput = inventory
        val vm = viewModel()
        advanceUntilIdle()
        vm.requestStopAll()
        assertTrue(vm.state.value.confirmStopAll)
        vm.confirmStopAll()
        advanceUntilIdle()
        assertEquals(
            listOf(ServerAgentInventory.stopPersistent(listOf(AGENT_1, AGENT_2)), ServerAgentInventory.stopPanel(listOf(4321 to panelID))),
            ssh.scripts,
        )
    }

    @Test
    fun `sin reposo automatico no hay candidatos`() = runTest(main.dispatcher) {
        settings.setHibernationHours(0)
        ssh.inventoryOutput = inventory
        val vm = viewModel()
        advanceUntilIdle()
        assertTrue(vm.state.value.candidates.isEmpty())
    }

    @Test
    fun `un fallo al detener se ve y no lo borra el refresco`() = runTest(main.dispatcher) {
        ssh.inventoryOutput = inventory
        val vm = viewModel()
        advanceUntilIdle()
        ssh.scriptError = networkDown()
        vm.stop(assertIs<ServerAgentsLoad.Loaded>(vm.state.value.load).inventory.liveAgents.first())
        advanceUntilIdle()
        assertEquals(UiText.Plain("Sin red"), vm.state.value.actionError)
        assertIs<ServerAgentsLoad.Loaded>(vm.state.value.load)
    }

    @Test
    fun `los agentes atascados se nombran`() = runTest(main.dispatcher) {
        ssh.inventoryOutput = inventory
        val vm = viewModel()
        advanceUntilIdle()
        ssh.scriptOutput = "${ServerAgentInventory.FAILED_MARKER} $AGENT_1\n"
        vm.stop(assertIs<ServerAgentsLoad.Loaded>(vm.state.value.load).inventory.liveAgents.first { it.sessionID == AGENT_1 })
        advanceUntilIdle()
        assertEquals(UiText.res(R.string.server_agents_failed, "quieto"), vm.state.value.actionError)
    }

    @Test
    fun `formatos de la pantalla`() {
        assertEquals("…/b/c", ServerAgentsFormat.shortPath("/srv/a/b/c"))
        assertEquals("~/x", ServerAgentsFormat.shortPath("~/x"))
        assertEquals("7 min", ServerAgentsFormat.idle(420))
        assertEquals("5 h 10 min", ServerAgentsFormat.idle(5 * 3600 + 600))
        assertEquals("2 d 3 h", ServerAgentsFormat.idle(2 * 86_400 + 3 * 3600 + 59))
        assertEquals("1 d", ServerAgentsFormat.idle(86_400))
    }
}
