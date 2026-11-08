@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.PersistentAgentException
import com.iaportafolio.argos.testing.FakeAgentService
import com.iaportafolio.argos.testing.FakeTerminalService
import com.iaportafolio.argos.testing.FakeTerminalSink
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTerminalSettings
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.networkDown
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.agents.AgentLoginEvent
import com.iaportafolio.argos.ui.agents.AgentLoginPhase
import com.iaportafolio.argos.ui.agents.AgentLoginPolicy
import com.iaportafolio.argos.ui.agents.AgentLoginViewModel
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.ReconnectPolicy
import com.iaportafolio.argos.ui.terminal.TerminalStatus
import com.iaportafolio.argos.ui.terminal.TerminalTarget
import com.iaportafolio.argos.ui.terminal.TerminalViewModel
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AgentLoginViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val ssh = FakeAgentService().apply { authStatus = ClaudeAuthStatus(false, null, null) }
    private val provider = SingleServiceProvider(ssh)
    private val policy = AgentLoginPolicy(verifyIntervalMillis = 2_000, verifyAttempts = 3, successDisplayMillis = 500)

    private val url = "https://claude.ai/oauth/authorize?code=true&client_id=abc"
    private val signedIn = ClaudeAuthStatus(true, "max", "yo@example.com")

    private fun viewModel() = AgentLoginViewModel("S1", repository, provider, policy)

    private fun AgentLoginViewModel.feed(text: String) = onTerminalOutput(listOf(text.toByteArray()))

    private fun TestScope.eventsOf(vm: AgentLoginViewModel): List<AgentLoginEvent> {
        val events = mutableListOf<AgentLoginEvent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.events.toList(events) }
        return events
    }

    @Test
    fun `el comando usa la ruta de claude entrecomillada`() = runTest(main.dispatcher) {
        ssh.claudePath = "/home/yo/mi claude/claude"
        assertEquals("'/home/yo/mi claude/claude' auth login --claudeai", viewModel().loginCommand(ssh))
    }

    @Test
    fun `sin claude instalado el comando falla con un error claro`() = runTest(main.dispatcher) {
        ssh.claudePath = null
        val error = runCatching { viewModel().loginCommand(ssh) }.exceptionOrNull()
        assertTrue(error is PersistentAgentException)
    }

    @Test
    fun `detecta el enlace aunque llegue en trozos y entre secuencias de terminal`() = runTest(main.dispatcher) {
        val vm = viewModel()
        assertEquals(AgentLoginPhase.Starting, vm.state.value.phase)

        vm.feed("Opening browser to sign in…\r\nIf the browser didn't open, visit: \u001B]8;;$url\u0007")
        vm.feed("$url\u001B]8;;\u0007\r\n")
        assertEquals(url, vm.state.value.authorizationUrl)
        assertEquals(AgentLoginPhase.Authorize, vm.state.value.phase)
        assertFalse(vm.state.value.isAwaitingCode)

        vm.feed("Paste code here if prompted > ")
        assertTrue(vm.state.value.isAwaitingCode)
        assertTrue(vm.state.value.canSubmitCode)
    }

    @Test
    fun `nunca ofrece abrir un enlace de otro dominio`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: https://evil.example.com/oauth/authorize\r\n")
        assertNull(vm.state.value.authorizationUrl)
        assertEquals(AgentLoginPhase.Starting, vm.state.value.phase)
    }

    @Test
    fun `una salida muy larga no crece sin límite y conserva el enlace encontrado`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\n")
        repeat(50) { vm.feed("x".repeat(1_000)) }
        assertEquals(url, vm.state.value.authorizationUrl)
    }

    @Test
    fun `el código se teclea limpio con retorno y empieza la comprobación`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\nPaste code here")
        val bytes = vm.submitCode("  abc#123\n")
        assertEquals("abc#123\r", bytes?.decodeToString())
        assertEquals(AgentLoginPhase.Verifying, vm.state.value.phase)
        assertFalse(vm.state.value.canSubmitCode)
    }

    @Test
    fun `un salto de línea en el código no teclea órdenes de más`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\nPaste code here")
        assertEquals("abcrm -rf\r", vm.submitCode("abc\nrm -rf")?.decodeToString())
    }

    @Test
    fun `no se envía código si el CLI no lo espera o está vacío`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\n")
        assertNull(vm.submitCode("abc"))
        vm.feed("Paste code here")
        assertNull(vm.submitCode("   "))
        assertEquals(AgentLoginPhase.Authorize, vm.state.value.phase)
    }

    @Test
    fun `al confirmarse la sesión lo dice y se cierra sola`() = runTest(main.dispatcher) {
        val vm = viewModel()
        val events = eventsOf(vm)
        vm.feed("visit: $url\r\nPaste code here")
        vm.submitCode("abc")

        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(AgentLoginPhase.Verifying, vm.state.value.phase)

        ssh.authStatus = signedIn
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(AgentLoginPhase.Success("max · yo@example.com"), vm.state.value.phase)
        assertTrue(events.isEmpty())

        advanceTimeBy(500)
        runCurrent()
        assertEquals(listOf<AgentLoginEvent>(AgentLoginEvent.Finished), events.toList())
    }

    @Test
    fun `si no se confirma lo dice y deja reintentar el código`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\nPaste code here")
        vm.submitCode("abc")
        advanceUntilIdle()
        assertEquals(AgentLoginPhase.Failed(UiText.res(R.string.agents_login_not_confirmed)), vm.state.value.phase)
        assertTrue(vm.state.value.canSubmitCode)
    }

    @Test
    fun `un fallo de red al comprobar no cierra el login`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\nPaste code here")
        ssh.authError = networkDown()
        vm.submitCode("abc")
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(AgentLoginPhase.Verifying, vm.state.value.phase)

        ssh.authError = null
        ssh.authStatus = signedIn
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(AgentLoginPhase.Success("max · yo@example.com"), vm.state.value.phase)
    }

    @Test
    fun `si el comando termina con sesión es un éxito aunque se tecleara en el terminal`() = runTest(main.dispatcher) {
        ssh.authStatus = signedIn
        val vm = viewModel()
        val events = eventsOf(vm)
        vm.onTerminalEnded()
        advanceUntilIdle()
        assertEquals(AgentLoginPhase.Success("max · yo@example.com"), vm.state.value.phase)
        assertEquals(listOf<AgentLoginEvent>(AgentLoginEvent.Finished), events.toList())
    }

    @Test
    fun `si el comando termina sin sesión lo dice`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onTerminalEnded()
        advanceUntilIdle()
        assertEquals(AgentLoginPhase.Failed(UiText.res(R.string.agents_login_ended)), vm.state.value.phase)
    }

    @Test
    fun `terminar mientras se comprueba no interrumpe la comprobación`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\nPaste code here")
        vm.submitCode("abc")
        vm.onTerminalEnded()
        assertEquals(AgentLoginPhase.Verifying, vm.state.value.phase)
        ssh.authStatus = signedIn
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(AgentLoginPhase.Success("max · yo@example.com"), vm.state.value.phase)
    }

    @Test
    fun `empezar de nuevo olvida el enlace anterior`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.feed("visit: $url\r\nPaste code here")
        vm.restart()
        assertEquals(AgentLoginPhase.Starting, vm.state.value.phase)
        assertNull(vm.state.value.authorizationUrl)
        assertFalse(vm.state.value.isAwaitingCode)
        vm.feed("nada útil")
        assertNull(vm.state.value.authorizationUrl)
    }

    @Test
    fun `el terminal solo se arranca una vez`() = runTest(main.dispatcher) {
        val vm = viewModel()
        assertTrue(vm.claimTerminalStart())
        assertFalse(vm.claimTerminalStart())
    }

    @Test
    fun `el terminal del login ejecuta el comando, alimenta los pasos y no se relanza solo`() = runTest(main.dispatcher) {
        val terminal = FakeTerminalService()
        val login = viewModel()
        val vm = TerminalViewModel(
            serverId = "S1",
            sessionName = "claude auth login",
            repository = repository,
            services = SingleServiceProvider(terminal),
            settingsStore = InMemoryTerminalSettings(),
            screen = FakeTerminalSink(),
            io = main.dispatcher,
            policy = ReconnectPolicy(maxAttempts = 0),
            target = TerminalTarget.Command { "'/bin/claude' auth login --claudeai" },
            outputTap = login::onTerminalOutput,
        )
        vm.onViewResized(100, 30)
        vm.onStart()
        runCurrent()
        assertEquals(listOf("'/bin/claude' auth login --claudeai"), terminal.commands)

        terminal.calls.single().emit("visit: $url\r\n")
        runCurrent()
        assertEquals(url, login.state.value.authorizationUrl)

        terminal.calls.single().end.complete(networkDown())
        runCurrent()
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(1, terminal.calls.size)
        assertEquals(TerminalStatus.Disconnected(UiText.Plain("Sin red"), null), vm.state.value.status)
        vm.onStop()
    }

    @Test
    fun `un servidor borrado no revienta la comprobación`() = runTest(main.dispatcher) {
        val vm = AgentLoginViewModel("no-existe", repository, provider, policy)
        vm.onTerminalEnded()
        advanceUntilIdle()
        assertEquals(AgentLoginPhase.Failed(UiText.res(R.string.agents_login_ended)), vm.state.value.phase)
    }
}
