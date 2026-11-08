@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.ActiveTerminalRegistry
import com.iaportafolio.argos.data.TerminalSettings
import com.iaportafolio.argos.testing.FakeKeepAliveHost
import com.iaportafolio.argos.testing.FakeTerminalService
import com.iaportafolio.argos.testing.FakeTerminalSink
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTerminalSettings
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.networkDown
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.ReconnectPolicy
import com.iaportafolio.argos.ui.terminal.TerminalStatus
import com.iaportafolio.argos.ui.terminal.TerminalViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TerminalKeepAliveTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val ssh = FakeTerminalService()
    private val sink = FakeTerminalSink()
    private val settings = InMemoryTerminalSettings()
    private val host = FakeKeepAliveHost()
    private val registry = ActiveTerminalRegistry(host) { settings.settings.value.keepAliveInBackground }
    private val policy = ReconnectPolicy(delaysMillis = listOf(1_000), maxAttempts = 1)

    private fun viewModel() = TerminalViewModel(
        "S1",
        "web",
        repository,
        SingleServiceProvider(ssh),
        settings,
        sink,
        main.dispatcher,
        policy,
        keepAlive = registry,
    )

    private suspend fun TestScope.connected(): TerminalViewModel<FakeTerminalSink> {
        val vm = viewModel()
        vm.onViewResized(100, 30)
        vm.onStart()
        runCurrent()
        ssh.calls.last().emit("hola")
        runCurrent()
        return vm
    }

    // MARK: - Ajuste activado

    @Test
    fun `al adjuntar se registra y arranca el servicio`() = runTest(main.dispatcher) {
        connected()
        assertEquals(1, registry.count.value)
        assertEquals(1, host.starts)
    }

    @Test
    fun `con el ajuste activo ON_STOP no hace detach y la salida sigue llegando`() = runTest(main.dispatcher) {
        val vm = connected()
        val call = ssh.calls.single()

        vm.onStop()
        runCurrent()

        assertFalse(call.cancelled)
        call.emit(" en segundo plano")
        runCurrent()
        assertEquals("hola en segundo plano", sink.fed.toString())
    }

    @Test
    fun `al volver sigue conectado sin reenganchar ni repintar`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onStop()
        runCurrent()

        vm.onStart()
        runCurrent()

        assertEquals(1, ssh.calls.size)
        assertEquals(0, sink.resets)
        assertEquals(TerminalStatus.Connected, vm.state.value.status)
    }

    @Test
    fun `salir de la pantalla hace detach aunque el ajuste esté activo`() = runTest(main.dispatcher) {
        val vm = connected()

        vm.onLeave()
        runCurrent()

        assertTrue(ssh.calls.single().cancelled)
        assertEquals(0, registry.count.value)
    }

    @Test
    fun `reconectar no suelta el registro`() = runTest(main.dispatcher) {
        val vm = connected()
        val counts = mutableListOf<Int>()
        vm.reconnect()
        counts += registry.count.value
        runCurrent()
        counts += registry.count.value

        assertEquals(listOf(1, 1), counts)
        assertEquals(1, host.starts)
    }

    @Test
    fun `al terminar la sesión se suelta el registro`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onStop()
        ssh.calls.single().end.complete(null)
        runCurrent()

        assertEquals(TerminalStatus.SessionEnded, vm.state.value.status)
        assertEquals(0, registry.count.value)
    }

    @Test
    fun `en segundo plano reintenta y al agotar los intentos suelta el registro`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onStop()
        ssh.openErrors += networkDown()
        ssh.calls.single().end.complete(networkDown())
        runCurrent()
        assertEquals(1, registry.count.value)

        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(0, registry.count.value)
        assertTrue(vm.state.value.status is TerminalStatus.Disconnected)
    }

    @Test
    fun `tras caerse en segundo plano y agotar intentos, volver reconecta y rearranca el servicio`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onStop()
        ssh.openErrors += networkDown()
        ssh.calls.single().end.complete(networkDown())
        runCurrent()
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(0, registry.count.value)

        vm.onStart()
        runCurrent()

        assertEquals(1, registry.count.value)
        assertEquals(2, ssh.calls.size)
        assertEquals(2, host.starts)
    }

    @Test
    fun `dos terminales cuentan dos y al cerrar uno sigue el servicio`() = runTest(main.dispatcher) {
        val first = connected()
        connected()
        assertEquals(2, registry.count.value)
        assertEquals(1, host.starts)

        first.onLeave()
        runCurrent()
        assertEquals(1, registry.count.value)
        assertTrue(registry.keepsAliveInBackground)
    }

    // MARK: - Ajuste desactivado

    @Test
    fun `con el ajuste desactivado ON_STOP hace detach y al volver reengancha`() = runTest(main.dispatcher) {
        settings.setKeepAliveInBackground(false)
        val vm = connected()
        assertEquals(0, host.starts)

        vm.onStop()
        runCurrent()
        assertTrue(ssh.calls.single().cancelled)
        assertEquals(0, registry.count.value)

        vm.onStart()
        runCurrent()
        assertEquals(2, ssh.calls.size)
        assertEquals(1, sink.resets)
    }

    // MARK: - Degradación

    @Test
    fun `si el servicio no arranca, ON_STOP hace detach como siempre`() = runTest(main.dispatcher) {
        host.allowed = false
        val vm = connected()

        vm.onStop()
        runCurrent()

        assertTrue(ssh.calls.single().cancelled)
        assertEquals(0, registry.count.value)
    }

    @Test
    fun `al volver a primer plano reintenta arrancar el servicio sin tocar la conexión`() = runTest(main.dispatcher) {
        host.allowed = false
        val vm = connected()
        host.allowed = true

        vm.onStart()
        runCurrent()

        assertEquals(2, host.starts)
        assertEquals(1, ssh.calls.size)
        vm.onStop()
        runCurrent()
        assertFalse(ssh.calls.single().cancelled)
    }

    @Test
    fun `si cae el servicio con la app en segundo plano hace detach`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onStop()

        registry.serviceLost()
        runCurrent()

        assertTrue(ssh.calls.single().cancelled)
        assertEquals(0, registry.count.value)
    }

    @Test
    fun `si cae el servicio con el terminal a la vista sigue conectado`() = runTest(main.dispatcher) {
        connected()

        registry.serviceLost()
        runCurrent()

        assertFalse(ssh.calls.single().cancelled)
        assertEquals(1, registry.count.value)
    }

    // MARK: - Desconectar todo

    @Test
    fun `desconectar todo hace detach, sin matar la sesión, y ofrece reconectar`() = runTest(main.dispatcher) {
        val vm = connected()

        registry.disconnectAll()
        runCurrent()

        val call = ssh.calls.single()
        assertTrue(call.cancelled)
        assertEquals(0, registry.count.value)
        assertFalse(ssh.killedSessions())
        assertEquals(
            TerminalStatus.Disconnected(UiText.res(R.string.terminal_disconnected_by_user), retryInSeconds = null),
            vm.state.value.status,
        )
    }

    @Test
    fun `tras desconectar todo, volver a primer plano reengancha`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onStop()
        registry.disconnectAll()
        runCurrent()

        vm.onStart()
        runCurrent()

        assertEquals(2, ssh.calls.size)
        assertEquals(1, registry.count.value)
    }

    @Test
    fun `desconectar todo no reabre una sesión terminada`() = runTest(main.dispatcher) {
        val vm = connected()
        val other = connected()
        ssh.calls.first().end.complete(null)
        runCurrent()

        registry.disconnectAll()
        runCurrent()

        assertEquals(TerminalStatus.SessionEnded, vm.state.value.status)
        assertTrue(other.state.value.status is TerminalStatus.Disconnected)
    }

    @Test
    fun `el valor por defecto del ajuste es activado`() {
        assertTrue(TerminalSettings().keepAliveInBackground)
    }
}
