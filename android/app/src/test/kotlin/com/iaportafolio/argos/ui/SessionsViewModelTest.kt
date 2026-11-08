@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import app.cash.turbine.test
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.session
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.sessions.ConnectStep
import com.iaportafolio.argos.ui.sessions.SessionDialog
import com.iaportafolio.argos.ui.sessions.SessionsLoad
import com.iaportafolio.argos.ui.sessions.SessionsViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SessionsViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val provider = FakeServiceProvider()
    private val ssh get() = provider.service
    private val trust = InMemoryTrustStore(mapOf("dev.example.com:22" to "SHA256:viejo"))

    private fun TestScope.viewModel(serverId: String = "S1") =
        SessionsViewModel(serverId, repository, provider, trust, main.dispatcher)

    private fun TestScope.loaded(): SessionsViewModel = viewModel().also { advanceUntilIdle() }

    @Test
    fun `conecta, arranca tmux y agrupa las sesiones como Apple`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"), session("web/api"), session("web/front", attached = true), session("Alpha/x"))
        val vm = loaded()

        val state = vm.state.value
        assertEquals(SessionsLoad.Loaded, state.load)
        assertEquals("dev", state.serverName)
        assertEquals(listOf("Alpha", "web", "General"), state.groups.map { it.name })
        assertEquals(listOf("web/api", "web/front"), state.groups[1].sessions.map { it.name })
        assertEquals(listOf("isTmuxInstalled", "configExists", "clipboard", "list"), ssh.calls)
    }

    @Test
    fun `emite los pasos de conexión y luego la lista`() = runTest(main.dispatcher) {
        val gate = CompletableDeferred<Unit>()
        ssh.listGate = gate
        ssh.sessions = listOf(session("main"))
        val vm = viewModel()

        vm.state.test {
            assertEquals(SessionsLoad.Connecting(ConnectStep.VERIFYING), awaitItem().load)
            val listing = awaitItem()
            assertEquals(SessionsLoad.Connecting(ConnectStep.LOADING), listing.load)
            assertTrue(listing.isBusy)
            gate.complete(Unit)
            assertEquals(SessionsLoad.Loaded, awaitItem().load)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `sin tmux y con sudo lo instala y configura`() = runTest(main.dispatcher) {
        ssh.tmuxInstalled = false
        ssh.canSudo = true
        ssh.configExists = false
        loaded()
        assertEquals(listOf("isTmuxInstalled", "canSudo", "install", "configExists", "writeConfig", "clipboard", "list"), ssh.calls)
    }

    @Test
    fun `sin tmux y sin sudo muestra la instrucción manual`() = runTest(main.dispatcher) {
        ssh.tmuxInstalled = false
        val vm = loaded()
        assertEquals(SessionsLoad.TmuxMissing, vm.state.value.load)
        assertTrue("list" !in ssh.calls)
    }

    @Test
    fun `TmuxNotInstalled del servicio también es tmux ausente`() = runTest(main.dispatcher) {
        ssh.listError = SSHServiceError.TmuxNotInstalled()
        assertEquals(SessionsLoad.TmuxMissing, loaded().state.value.load)
    }

    @Test
    fun `error de red se muestra con userMessage y reintentar reconecta`() = runTest(main.dispatcher) {
        provider.error = IOException("Conexión rechazada")
        val vm = loaded()
        assertEquals(SessionsLoad.Failed("Conexión rechazada"), vm.state.value.load)

        provider.error = null
        vm.load()
        advanceUntilIdle()
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
    }

    @Test
    fun `huella cambiada (también envuelta) ofrece olvidarla y reintentar`() = runTest(main.dispatcher) {
        val mismatch = HostKeyMismatchException("dev.example.com:22", "SHA256:viejo", "SHA256:nuevo")
        provider.error = IOException("transporte", mismatch)
        val vm = loaded()
        val state = assertIs<SessionsLoad.HostKeyChanged>(vm.state.value.load)
        assertTrue(state.message.contains("SHA256:nuevo"))

        provider.error = null
        vm.forgetHostKeyAndRetry()
        advanceUntilIdle()

        assertNull(trust.known["dev.example.com:22"])
        assertEquals(listOf("S1"), provider.invalidated)
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
    }

    @Test
    fun `servidor inexistente`() = runTest(main.dispatcher) {
        val vm = viewModel(serverId = "nope").also { advanceUntilIdle() }
        assertEquals(SessionsLoad.ServerMissing, vm.state.value.load)
    }

    @Test
    fun `refresh con la lista visible solo re-lista y conserva la lista si falla`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"))
        val vm = loaded()
        ssh.calls.clear()

        ssh.sessions = listOf(session("main"), session("otra"))
        vm.refresh()
        advanceUntilIdle()
        assertEquals(listOf("list"), ssh.calls)
        assertEquals(2, vm.state.value.groups.single().sessions.size)
        assertEquals(false, vm.state.value.isRefreshing)

        ssh.listError = IOException("se cayó")
        vm.refresh()
        advanceUntilIdle()
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
        assertEquals(2, vm.state.value.groups.single().sessions.size)
        assertEquals(UiText.Plain("se cayó"), vm.state.value.message)
    }

    @Test
    fun `crear valida en vivo, crea y recarga`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.openCreate()
        vm.onDialogTextChange("mal:nombre")
        val invalid = assertIs<SessionDialog.Create>(vm.state.value.dialog)
        assertNotNull(invalid.error)

        vm.submitDialog()
        assertTrue("create:mal:nombre" !in ssh.calls)

        vm.onDialogTextChange("  web/api  ")
        assertNull((vm.state.value.dialog as SessionDialog.Create).error)
        vm.submitDialog()
        advanceUntilIdle()

        assertTrue("create:web/api" in ssh.calls)
        assertNull(vm.state.value.dialog)
        assertEquals(listOf("web/api"), vm.state.value.groups.flatMap { g -> g.sessions.map { it.name } })
    }

    @Test
    fun `un error al crear se queda en el diálogo`() = runTest(main.dispatcher) {
        val vm = loaded()
        ssh.managementError = SSHServiceError.CommandFailed(1, "duplicate session: main")
        vm.openCreate()
        vm.onDialogTextChange("main")
        vm.submitDialog()
        advanceUntilIdle()

        val dialog = assertIs<SessionDialog.Create>(vm.state.value.dialog)
        assertEquals(false, dialog.isSubmitting)
        assertTrue(dialog.error.orEmpty().contains("duplicate session"))
    }

    @Test
    fun `renombrar al mismo nombre solo cierra y a otro renombra`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"))
        val vm = loaded()
        vm.openRename(session("main"))
        vm.submitDialog()
        assertNull(vm.state.value.dialog)
        assertTrue(ssh.calls.none { it.startsWith("rename") })

        vm.openRename(session("main"))
        vm.onDialogTextChange("principal")
        vm.submitDialog()
        advanceUntilIdle()
        assertTrue("rename:main->principal" in ssh.calls)
        assertEquals("principal", vm.state.value.groups.single().sessions.single().name)
    }

    @Test
    fun `matar pide confirmación y un fallo se avisa sin perder la lista`() = runTest(main.dispatcher) {
        ssh.sessions = listOf(session("main"), session("b"))
        val vm = loaded()

        vm.requestKill(session("main"))
        assertIs<SessionDialog.ConfirmKill>(vm.state.value.dialog)
        vm.dismissDialog()
        assertNull(vm.state.value.dialog)
        assertTrue(ssh.calls.none { it.startsWith("kill") })

        vm.requestKill(session("main"))
        vm.confirmKill()
        advanceUntilIdle()
        assertEquals(listOf("b"), vm.state.value.groups.single().sessions.map { it.name })

        ssh.managementError = IOException("sin permiso")
        vm.requestKill(session("b"))
        vm.confirmKill()
        advanceUntilIdle()
        assertEquals(UiText.Plain("sin permiso"), vm.state.value.message)
        assertEquals(SessionsLoad.Loaded, vm.state.value.load)
    }

    @Test
    fun `tocar una sesión avisa de la fase 3`() = runTest(main.dispatcher) {
        val vm = loaded()
        vm.onSessionClick(session("main"))
        assertEquals(UiText.res(R.string.sessions_terminal_coming, "main"), vm.state.value.message)
        vm.messageShown()
        assertNull(vm.state.value.message)
    }

    @Test
    fun `el nombre del servidor sigue a las ediciones`() = runTest(main.dispatcher) {
        val vm = loaded()
        repository.upsert(server(name = "producción"))
        advanceUntilIdle()
        assertEquals("producción", vm.state.value.serverName)
    }
}
