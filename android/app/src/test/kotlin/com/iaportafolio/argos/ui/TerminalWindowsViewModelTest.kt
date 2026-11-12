@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.TerminalWindowsViewModel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TerminalWindowsViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val provider = FakeServiceProvider()
    private val ssh get() = provider.service

    private val shell = TmuxWindow(1, "zsh", isActive = true, paneCount = 1, currentCommand = "zsh")
    private val claude = TmuxWindow(2, "Claude Code", isActive = false, paneCount = 1, currentCommand = "claude")

    private fun viewModel(projectPath: String? = "/srv/api") =
        TerminalWindowsViewModel("S1", "web/api", projectPath, repository, provider, main.dispatcher)

    /** Arranca el sondeo (como hace la pantalla) y deja pasar la primera lectura. */
    private fun TestScope.polling(vm: TerminalWindowsViewModel) {
        backgroundScope.launch { vm.pollWhileVisible() }
        runCurrent()
    }

    @Test
    fun `lee las ventanas y los agentes instalados al hacerse visible`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        ssh.installedAgents = setOf(CodingAgent.CLAUDE)
        val vm = viewModel()
        assertTrue(vm.state.value.windows.isEmpty())
        polling(vm)
        assertEquals(listOf(shell, claude), vm.state.value.windows)
        assertEquals(setOf(CodingAgent.CLAUDE), vm.state.value.installedAgents)
    }

    @Test
    fun `se relee cada pocos segundos`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell)
        val vm = viewModel()
        polling(vm)
        ssh.windows = listOf(shell, claude)
        advanceTimeBy(TerminalWindowsViewModel.POLL_INTERVAL_MILLIS + 1)
        assertEquals(2, vm.state.value.windows.size)
    }

    @Test
    fun `si el servidor no responde espacia los intentos y conserva las pestañas`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell)
        val vm = viewModel()
        polling(vm)
        ssh.windowsError = IOException("sin red")
        advanceTimeBy(TerminalWindowsViewModel.POLL_INTERVAL_MILLIS + 1)
        val afterFirstFailure = ssh.listWindowsRequests
        // El siguiente intento ya no llega a los 4 s, sino a los 8.
        advanceTimeBy(TerminalWindowsViewModel.POLL_INTERVAL_MILLIS + 1)
        assertEquals(afterFirstFailure, ssh.listWindowsRequests)
        advanceTimeBy(TerminalWindowsViewModel.POLL_INTERVAL_MILLIS)
        assertEquals(afterFirstFailure + 1, ssh.listWindowsRequests)
        assertEquals(listOf(shell), vm.state.value.windows)
        assertNull(vm.state.value.message)
    }

    @Test
    fun `seleccionar cambia la ventana activa`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        polling(vm)
        vm.select(claude)
        runCurrent()
        assertTrue("selectWindow:web/api:2" in ssh.calls)
        assertEquals(2, vm.state.value.windows.single { it.isActive }.index)
    }

    @Test
    fun `seleccionar marca la pestaña al instante y vale aunque la lista vaya por detrás`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        polling(vm)
        vm.select(claude)
        assertEquals(2, vm.state.value.windows.single { it.isActive }.index)
        runCurrent()
        // La lista decía que la 1 estaba activa, pero en tmux ya no: se selecciona igualmente.
        vm.select(shell)
        runCurrent()
        assertTrue("selectWindow:web/api:1" in ssh.calls)
    }

    @Test
    fun `abre un terminal y un agente en la carpeta del proyecto`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell)
        val vm = viewModel()
        polling(vm)
        vm.newWindow()
        runCurrent()
        vm.newAgentWindow(CodingAgent.CLAUDE)
        runCurrent()
        assertTrue("newWindow:web/api" in ssh.calls)
        assertTrue("newAgentWindow:web/api:claude:/srv/api" in ssh.calls)
        assertEquals(3, vm.state.value.windows.size)
    }

    @Test
    fun `en una sesión suelta el agente arranca sin carpeta`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell)
        val vm = viewModel(projectPath = null)
        vm.newAgentWindow(CodingAgent.CODEX)
        runCurrent()
        assertTrue("newAgentWindow:web/api:codex:null" in ssh.calls)
    }

    @Test
    fun `un shell ocioso se cierra sin preguntar`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        vm.requestClose(1)
        runCurrent()
        assertTrue("killWindow:web/api:1" in ssh.calls)
        assertNull(vm.state.value.closing)
        assertEquals(listOf(claude), vm.state.value.windows)
    }

    @Test
    fun `con algo corriendo pide confirmación antes de cerrar`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        vm.requestClose(2)
        runCurrent()
        assertEquals(claude, vm.state.value.closing)
        assertTrue(ssh.calls.none { it.startsWith("killWindow") })

        vm.confirmClose()
        runCurrent()
        assertTrue("killWindow:web/api:2" in ssh.calls)
        assertNull(vm.state.value.closing)
    }

    @Test
    fun `cancelar la confirmación no cierra nada`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        vm.requestClose(2)
        runCurrent()
        vm.dismissClose()
        runCurrent()
        assertNull(vm.state.value.closing)
        assertTrue(ssh.calls.none { it.startsWith("killWindow") })
    }

    @Test
    fun `la última ventana no se cierra`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell)
        val vm = viewModel()
        vm.requestClose(1)
        runCurrent()
        assertTrue(ssh.calls.none { it.startsWith("killWindow") })
        assertEquals(UiText.res(R.string.terminal_window_last), vm.state.value.message)
    }

    @Test
    fun `la confirmación se retira si la ventana desaparece`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        vm.requestClose(2)
        runCurrent()
        ssh.windows = listOf(shell)
        polling(vm)
        assertNull(vm.state.value.closing)
    }

    @Test
    fun `no cierra otra ventana que reutilizó el índice`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        vm.requestClose(2)
        runCurrent()
        val pending = vm.state.value.closing
        ssh.windows = listOf(shell, TmuxWindow(2, "vim", isActive = false, paneCount = 1, currentCommand = "vim"))
        // Aún sin releer: el diálogo sigue abierto y el usuario confirma.
        assertEquals(claude, pending)
        vm.confirmClose()
        runCurrent()
        assertTrue(ssh.calls.none { it.startsWith("killWindow") })
        assertEquals(2, vm.state.value.windows.size)
    }

    @Test
    fun `no cierra la ventana confirmada si se quedó como la última`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell, claude)
        val vm = viewModel()
        vm.requestClose(2)
        runCurrent()
        ssh.windows = listOf(claude)
        vm.confirmClose()
        runCurrent()
        assertTrue(ssh.calls.none { it.startsWith("killWindow") })
        assertEquals(UiText.res(R.string.terminal_window_last), vm.state.value.message)
    }

    @Test
    fun `un fallo de una acción se avisa`() = runTest(main.dispatcher) {
        ssh.windows = listOf(shell)
        ssh.windowActionError = IOException("tmux no responde")
        val vm = viewModel()
        vm.newWindow()
        runCurrent()
        assertIs<UiText.Plain>(vm.state.value.message)
        vm.messageShown()
        assertNull(vm.state.value.message)
    }
}
