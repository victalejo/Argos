@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.ports.ListeningPort
import com.iaportafolio.argos.core.ports.PortForwardException
import com.iaportafolio.argos.testing.FakePortForwardService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryPortForwardSettings
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.ports.PortForwardsViewModel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Pantalla «Puertos» (paridad con la suite `PortForwardsModel` de `PortForwardingTests.swift`). */
class PortForwardsViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val ports = FakePortForwardService()
    private val settings = InMemoryPortForwardSettings()
    private val repository = InMemoryServerRepository(listOf(server()))
    private val web = ListeningPort(3000, "localhost", "node")
    private val dns = ListeningPort(53, "localhost", null)

    private fun TestScope.loaded(): PortForwardsViewModel =
        PortForwardsViewModel("S1", repository, SingleServiceProvider(ports), settings, main.dispatcher).also { runCurrent() }

    @Test
    fun `carga los puertos y oculta los de sistema`() = runTest(main.dispatcher) {
        ports.listening = listOf(dns, web)
        val vm = loaded()
        val state = vm.state.value
        assertTrue(state.hasLoaded)
        assertEquals(listOf(web), state.visiblePorts)
        assertEquals(1, state.hiddenSystemPortCount)
        vm.setShowSystemPorts(true)
        assertEquals(2, vm.state.value.visiblePorts.size)
    }

    @Test
    fun `reenviar y abrir usa el mismo puerto o el siguiente libre y pide abrirlo`() = runTest(main.dispatcher) {
        ports.listening = listOf(web)
        ports.busyLocalPorts = setOf(3000)
        val vm = loaded()
        vm.startAndOpen(web)
        runCurrent()
        assertEquals("http://localhost:3001", vm.openRequests.first())
        assertEquals(3001, vm.state.value.forwardFor(3000)?.localPort)
        // Otra vez: reutiliza el túnel, no abre otro.
        vm.startAndOpen(web)
        runCurrent()
        assertEquals("http://localhost:3001", vm.openRequests.first())
        assertEquals(1, ports.forwards.size)
        assertTrue(vm.state.value.busyPorts.isEmpty())
    }

    @Test
    fun `puerto manual y cierre`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.setManualPort("80a80")
        assertEquals("8080", vm.state.value.manualPort)
        vm.startManual()
        runCurrent()
        assertEquals("", vm.state.value.manualPort)
        val forward = vm.state.value.forwards.single()
        assertEquals(8080, forward.remotePort)
        vm.stop(forward)
        runCurrent()
        assertTrue(vm.state.value.forwards.isEmpty())
        assertTrue(ports.forwards.isEmpty())
    }

    @Test
    fun `errores visibles y puerto invalido`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.setManualPort("0")
        vm.startManual()
        assertEquals(UiText.res(R.string.ports_invalid), vm.state.value.message)
        vm.messageShown()
        ports.forwardError = PortForwardException.bindFailed("ocupado")
        vm.setManualPort("3000")
        vm.startManual()
        runCurrent()
        val message = assertIs<UiText.Plain>(vm.state.value.message)
        assertTrue("ocupado" in message.value)
        assertTrue(vm.state.value.busyPorts.isEmpty())
    }

    @Test
    fun `se refresca solo cada pocos segundos`() = runTest(main.dispatcher) {
        val vm = loaded()
        assertEquals(1, ports.listRequests)
        backgroundScope.launch { vm.pollWhileVisible() }
        advanceTimeBy(PortForwardsViewModel.POLL_INTERVAL_MILLIS + 1)
        assertEquals(2, ports.listRequests)
    }

    @Test
    fun `un servicio sin reenvio muestra el error`() = runTest(main.dispatcher) {
        val vm = PortForwardsViewModel("S1", repository, SingleServiceProvider(FakeSSHService()), settings, main.dispatcher)
        runCurrent()
        assertTrue(vm.state.value.hasLoaded)
        assertIs<UiText.Plain>(vm.state.value.listError)
    }

    @Test
    fun `el limite de cierre automatico se guarda`() = runTest(main.dispatcher) {
        settings.idleMinutes = 30
        val vm = loaded()
        assertEquals(30, vm.state.value.idleMinutes)
        vm.setIdleMinutes(0)
        assertEquals(0, settings.idleMinutes)
        assertEquals(0, vm.state.value.idleMinutes)
    }
}
