@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.CreationExtras
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.TerminalControlEvent
import com.iaportafolio.argos.data.MissingCredentialsException
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.FakeTerminalService
import com.iaportafolio.argos.testing.FakeTerminalSink
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTerminalSettings
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.ExtraKey
import com.iaportafolio.argos.ui.terminal.ModifierLatch
import com.iaportafolio.argos.ui.terminal.ReconnectPolicy
import com.iaportafolio.argos.ui.terminal.TerminalStatus
import com.iaportafolio.argos.ui.terminal.TerminalViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.reflect.KClass
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class TerminalViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val ssh = FakeTerminalService()
    private val provider = SingleServiceProvider(ssh)
    private val sink = FakeTerminalSink()
    private val settings = InMemoryTerminalSettings()
    private val policy = ReconnectPolicy(delaysMillis = listOf(1_000, 2_000, 4_000), maxAttempts = 3)

    private fun TestScope.viewModel(serverId: String = "S1") =
        TerminalViewModel(serverId, "web/api", repository, provider, settings, sink, main.dispatcher, policy)

    /** VM medido a 100x30 y enganchado con salida inicial (estado conectado). */
    private suspend fun TestScope.connected(): TerminalViewModel<FakeTerminalSink> {
        val vm = viewModel()
        vm.onViewResized(100, 30)
        vm.onStart()
        runCurrent()
        ssh.calls.last().emit("hola")
        runCurrent()
        return vm
    }

    private fun ByteArray.text() = String(this, Charsets.UTF_8)

    @Test
    fun `engancha con el tamaño medido, vuelca la salida y pasa a conectado`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onViewResized(100, 30)
        vm.onStart()
        runCurrent()

        assertEquals(TerminalStatus.Connecting(0), vm.state.value.status)
        val call = ssh.calls.single()
        assertEquals(Triple("web/api", 100, 30), Triple(call.session, call.cols, call.rows))
        assertEquals("dev", vm.state.value.serverName)

        call.emit("hola ")
        call.emit("mundo")
        runCurrent()
        assertEquals("hola mundo", sink.fed.toString())
        assertEquals(TerminalStatus.Connected, vm.state.value.status)
        assertEquals(0, sink.resets)
    }

    @Test
    fun `sin medición espera un poco y abre a 80x24`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onStart()
        advanceTimeBy(policy.initialSizeWaitMillis - 1)
        runCurrent()
        assertTrue(ssh.calls.isEmpty())
        advanceTimeBy(2)
        runCurrent()
        assertEquals(80 to 24, ssh.calls.single().let { it.cols to it.rows })
    }

    @Test
    fun `un tamaño transitorio inútil abre con el de respaldo`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onViewResized(4, 2)
        vm.onStart()
        runCurrent()
        assertEquals(80 to 24, ssh.calls.single().let { it.cols to it.rows })
    }

    @Test
    fun `el texto del IME y las teclas extra llegan como Input`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.typeText("ñá😀")
        vm.pressExtraKey(ExtraKey.UP)
        sink.cursorKeysApplicationMode = true
        vm.pressExtraKey(ExtraKey.UP)
        vm.pressExtraKey(ExtraKey.TMUX_PREFIX)
        runCurrent()

        assertEquals(listOf("ñá😀", "\u001B[A", "\u001BOA", "\u0002"), ssh.calls.single().inputs.map { it.text() })
    }

    @Test
    fun `Ctrl pegajoso se aplica a la siguiente tecla y se apaga`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.pressExtraKey(ExtraKey.CTRL)
        assertEquals(ModifierLatch.ONCE, vm.state.value.modifiers.ctrl)
        vm.typeText("c")
        assertEquals(ModifierLatch.OFF, vm.state.value.modifiers.ctrl)
        vm.typeText("c")
        runCurrent()
        assertEquals(listOf(listOf<Byte>(0x03), listOf('c'.code.toByte())), ssh.calls.single().inputs.map { it.toList() })
    }

    @Test
    fun `teclado físico combina sus modificadores con los pegajosos`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.typeHardwareCodePoint('d'.code, ctrl = true, alt = false)
        vm.pressExtraKey(ExtraKey.ALT)
        vm.typeHardwareCodePoint('b'.code, ctrl = false, alt = false)
        vm.pressExtraKey(ExtraKey.CTRL)
        vm.sendKeySequence("\u001B[1;5A")
        runCurrent()

        assertEquals(listOf("\u0004", "\u001Bb", "\u001B[1;5A"), ssh.calls.single().inputs.map { it.text() })
        assertEquals(ModifierLatch.OFF, vm.state.value.modifiers.ctrl)
        assertEquals(ModifierLatch.OFF, vm.state.value.modifiers.alt)
    }

    @Test
    fun `las respuestas del emulador y el pegado salen por el PTY`() = runTest(main.dispatcher) {
        val vm = connected()
        sink.respond("\u001B[?64;1c")
        vm.paste("ls -la")
        vm.paste("")
        runCurrent()
        assertEquals(listOf("ls -la"), sink.pasted)
        assertEquals(listOf("\u001B[?64;1c", "\u001B[200~ls -la\u001B[201~"), ssh.calls.single().inputs.map { it.text() })
    }

    @Test
    fun `sin attach abierto la entrada se descarta`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.typeText("perdido")
        vm.onViewResized(100, 30)
        vm.onStart()
        runCurrent()
        assertTrue(ssh.calls.single().inputs.isEmpty())
    }

    @Test
    fun `el resize espera al debounce y solo envía el último tamaño`() = runTest(main.dispatcher) {
        val vm = connected()
        val call = ssh.calls.single()
        vm.onViewResized(101, 30)
        advanceTimeBy(100)
        vm.onViewResized(90, 40)
        advanceTimeBy(policy.resizeDebounceMillis - 1)
        runCurrent()
        assertTrue(call.resizes.isEmpty())

        advanceTimeBy(2)
        runCurrent()
        assertEquals(listOf(TerminalControlEvent.Resize(90, 40)), call.resizes)
    }

    @Test
    fun `no reenvía el tamaño que ya tiene el PTY ni tamaños transitorios`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onViewResized(100, 30)
        advanceUntilIdle()
        vm.onViewResized(10, 3)
        advanceUntilIdle()
        assertTrue(ssh.calls.single().resizes.isEmpty())
    }

    @Test
    fun `una caída reintenta con backoff y al volver reinicia el emulador`() = runTest(main.dispatcher) {
        val vm = connected()
        ssh.calls.single().end.complete(IOException("red caída"))
        runCurrent()
        assertEquals(TerminalStatus.Disconnected(UiText.Plain("red caída"), retryInSeconds = 1), vm.state.value.status)

        ssh.openErrors += IOException("sigue caída")
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(2, ssh.openAttempts)
        assertEquals(TerminalStatus.Disconnected(UiText.Plain("sigue caída"), retryInSeconds = 2), vm.state.value.status)

        advanceTimeBy(1_998)
        runCurrent()
        assertEquals(2, ssh.openAttempts)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(3, ssh.openAttempts)
        assertEquals(TerminalStatus.Connecting(2), vm.state.value.status)
        assertEquals(1, sink.resets)

        ssh.calls.last().emit("repintado")
        runCurrent()
        assertEquals(TerminalStatus.Connected, vm.state.value.status)
        assertEquals("repintado", sink.fed.toString())
    }

    @Test
    fun `agotados los reintentos queda en manos del usuario`() = runTest(main.dispatcher) {
        repeat(4) { ssh.openErrors += IOException("inalcanzable") }
        val vm = viewModel()
        vm.onViewResized(100, 30)
        vm.onStart()
        advanceUntilIdle()

        assertEquals(4, ssh.openAttempts)
        assertEquals(TerminalStatus.Disconnected(UiText.Plain("inalcanzable"), retryInSeconds = null), vm.state.value.status)
        // 1 + 2 + 4 s de esperas (la última se repite) antes de rendirse.
        assertEquals(7_000, currentTime)

        vm.reconnect()
        runCurrent()
        assertEquals(1, ssh.calls.size)
    }

    @Test
    fun `una caída tras conectar reinicia la cuenta de reintentos`() = runTest(main.dispatcher) {
        val vm = connected()
        ssh.calls.single().end.complete(IOException("uno"))
        runCurrent()
        advanceTimeBy(1_001)
        runCurrent()
        ssh.calls.last().emit("ok")
        runCurrent()
        ssh.calls.last().end.complete(IOException("dos"))
        runCurrent()
        assertEquals(TerminalStatus.Disconnected(UiText.Plain("dos"), retryInSeconds = 1), vm.state.value.status)
    }

    @Test
    fun `fallos que exigen acción del usuario no se reintentan`() = runTest(main.dispatcher) {
        ssh.openErrors += HostKeyMismatchException("dev.example.com:22", "SHA256:a", "SHA256:b")
        val vm = viewModel()
        vm.onViewResized(100, 30)
        vm.onStart()
        advanceUntilIdle()

        val status = assertIs<TerminalStatus.Disconnected>(vm.state.value.status)
        assertEquals(null, status.retryInSeconds)
        assertEquals(1, ssh.openAttempts)
    }

    @Test
    fun `credenciales que faltan se muestran sin reintentar`() = runTest(main.dispatcher) {
        provider.error = MissingCredentialsException("Falta la contraseña")
        val vm = viewModel()
        vm.onViewResized(100, 30)
        vm.onStart()
        advanceUntilIdle()
        assertEquals(TerminalStatus.Disconnected(UiText.Plain("Falta la contraseña"), null), vm.state.value.status)
    }

    @Test
    fun `un servicio sin TerminalStreaming da un error claro`() = runTest(main.dispatcher) {
        provider.service = FakeSSHService()
        val vm = viewModel()
        vm.onViewResized(100, 30)
        vm.onStart()
        advanceUntilIdle()
        assertEquals(TerminalStatus.Disconnected(UiText.res(R.string.terminal_unsupported), null), vm.state.value.status)
    }

    @Test
    fun `servidor borrado`() = runTest(main.dispatcher) {
        val vm = viewModel(serverId = "nope")
        vm.onStart()
        advanceUntilIdle()
        assertEquals(TerminalStatus.Disconnected(UiText.res(R.string.terminal_server_missing), null), vm.state.value.status)
    }

    @Test
    fun `EOF de tmux es sesión terminada y no se reengancha solo`() = runTest(main.dispatcher) {
        val vm = connected()
        ssh.calls.single().end.complete(null)
        advanceUntilIdle()
        assertEquals(TerminalStatus.SessionEnded, vm.state.value.status)

        vm.onStop()
        vm.onStart()
        advanceUntilIdle()
        assertEquals(1, ssh.calls.size)

        vm.reconnect()
        runCurrent()
        assertEquals(2, ssh.calls.size)
        assertEquals(TerminalStatus.Connecting(0), vm.state.value.status)
    }

    @Test
    fun `segundo plano hace detach y al volver reengancha con la pantalla reiniciada`() = runTest(main.dispatcher) {
        val vm = connected()
        val first = ssh.calls.single()
        vm.onStop()
        runCurrent()
        assertTrue(first.cancelled)
        assertTrue(first.closed)

        vm.typeText("x")
        vm.onViewResized(120, 40)
        vm.onStart()
        runCurrent()
        val second = ssh.calls.last()
        assertEquals(2, ssh.calls.size)
        assertEquals(120 to 40, second.cols to second.rows)
        assertEquals(1, sink.resets)
        assertTrue(first.inputs.isEmpty())
    }

    @Test
    fun `onStart con un attach vivo no abre otro`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.onStart()
        runCurrent()
        assertEquals(1, ssh.calls.size)
    }

    @Test
    fun `reconectar cierra el canal anterior antes de abrir otro`() = runTest(main.dispatcher) {
        val vm = connected()
        vm.reconnect()
        runCurrent()
        assertTrue(ssh.calls.first().closed)
        assertEquals(2, ssh.calls.size)
        assertFalse(ssh.calls.last().closed)
    }

    @Test
    fun `segundo plano durante la espera de un reintento la cancela`() = runTest(main.dispatcher) {
        val vm = connected()
        ssh.calls.single().end.complete(IOException("caída"))
        runCurrent()
        vm.onStop()
        advanceUntilIdle()
        assertEquals(1, ssh.openAttempts)

        vm.onStart()
        runCurrent()
        assertEquals(2, ssh.openAttempts)
        assertEquals(TerminalStatus.Connecting(0), vm.state.value.status)
    }

    @Test
    fun `salir de la pantalla (ViewModel destruido) cancela el attach`() = runTest(main.dispatcher) {
        val store = ViewModelStore()
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: KClass<T>, extras: CreationExtras): T {
                @Suppress("UNCHECKED_CAST")
                return viewModel() as T
            }
        }
        val vm = ViewModelProvider.create(store, factory)[TerminalViewModel::class]
        vm.onViewResized(100, 30)
        vm.onStart()
        runCurrent()
        val call = ssh.calls.single()

        store.clear()
        runCurrent()
        assertTrue(call.cancelled)
        assertTrue(call.closed)
    }

    @Test
    fun `los ajustes se reflejan en el estado`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.setFontSize(18)
        vm.setKeepScreenOn(false)
        runCurrent()
        assertEquals(18, vm.state.value.settings.fontSizeSp)
        assertFalse(vm.state.value.settings.keepScreenOn)
        vm.setFontSize(500)
        runCurrent()
        assertEquals(32, vm.state.value.settings.fontSizeSp)
    }

    @Test
    fun `la salida se vuelca en lotes`() = runTest(main.dispatcher) {
        val vm = connected()
        val call = ssh.calls.single()
        val before = sink.feedBatches
        repeat(10) { call.emit("x") }
        runCurrent()
        assertEquals("hola" + "x".repeat(10), sink.fed.toString())
        assertTrue(sink.feedBatches - before < 10)
        assertEquals(TerminalStatus.Connected, vm.state.value.status)
    }
}
