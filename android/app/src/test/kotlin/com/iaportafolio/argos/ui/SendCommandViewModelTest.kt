package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.projects.SendCommandViewModel
import com.iaportafolio.argos.ui.terminal.TerminalWindowsViewModel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** «Enviar comando» a varias sesiones y paneles de tmux. */
class SendCommandViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val provider = FakeServiceProvider()
    private val repository = InMemoryServerRepository(listOf(server()))

    @Test
    fun `teclea el comando con Intro en las sesiones marcadas`() = runTest(main.dispatcher) {
        val vm = SendCommandViewModel("S1", repository, provider, main.dispatcher)
        vm.open(listOf("web", "api", "docs"))
        vm.toggle("docs")
        assertFalse(vm.state.value?.canSend == true)
        vm.onText("git pull")
        vm.send()
        advanceUntilIdle()

        assertEquals(listOf("sendKeys:web:git pull:true", "sendKeys:api:git pull:true"), provider.service.calls)
        assertNull(vm.state.value)
        assertEquals(UiText.res(R.string.send_command_sent, 2), vm.message.value)
    }

    @Test
    fun `si falla se queda abierto con las sesiones que faltan`() = runTest(main.dispatcher) {
        provider.service.sendKeysError = java.io.IOException("caído")
        val vm = SendCommandViewModel("S1", repository, provider, main.dispatcher)
        vm.open(listOf("web"))
        vm.onText("ls")
        vm.send()
        advanceUntilIdle()
        assertEquals(setOf("web"), vm.state.value?.selected)
        assertTrue(vm.state.value?.error.orEmpty().startsWith("web:"))
    }

    @Test
    fun `paneles sobre la ventana activa y nunca cerrar el unico`() = runTest(main.dispatcher) {
        val ssh = provider.service
        ssh.windows = listOf(TmuxWindow(1, "zsh", isActive = true, paneCount = 1, currentCommand = "zsh"))
        val vm = TerminalWindowsViewModel("S1", "web", null, repository, provider, main.dispatcher)
        backgroundScope.launch { vm.pollWhileVisible() }
        runCurrent()

        vm.splitPane(vertical = true)
        vm.zoomPane()
        vm.killPane()
        runCurrent()
        assertTrue("splitPane:web:true" in ssh.calls)
        assertTrue("zoomPane:web" in ssh.calls)
        assertFalse(ssh.calls.any { it.startsWith("killPane") })
        assertEquals(UiText.res(R.string.terminal_pane_last), vm.state.value.message)
    }
}
