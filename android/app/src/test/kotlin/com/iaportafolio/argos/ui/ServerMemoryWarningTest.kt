@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import androidx.lifecycle.SavedStateHandle
import app.cash.turbine.test
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.monitor.ServerMemoryPressureLevel
import com.iaportafolio.argos.core.monitor.ServerMemoryReading
import com.iaportafolio.argos.core.monitor.ServerMemoryWarning
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryProjectPreferences
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.project
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.session
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.monitor.messageText
import com.iaportafolio.argos.ui.monitor.titleText
import com.iaportafolio.argos.ui.project.ProjectLoad
import com.iaportafolio.argos.ui.project.ProjectViewModel
import com.iaportafolio.argos.ui.projects.ProjectsDialog
import com.iaportafolio.argos.ui.projects.ProjectsEvent
import com.iaportafolio.argos.ui.projects.ProjectsViewModel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Aviso de memoria del servidor: lista de proyectos, confirmación al arrancar y textos. */
class ServerMemoryWarningTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val provider = FakeServiceProvider()
    private val ssh get() = provider.service
    private val api = project(1, "api")

    /** Sin swap: [free] es la fracción libre exacta. */
    private fun memory(free: Double, claude: Int? = null) =
        ServerMemoryReading(1_000_000, (free * 1_000_000).toLong(), 0, 0, claude)

    private fun TestScope.projects(): ProjectsViewModel =
        ProjectsViewModel("S1", repository, provider, InMemoryTrustStore(), InMemoryProjectPreferences(), main.dispatcher)
            .also { advanceUntilIdle() }

    private fun TestScope.detail(): ProjectViewModel =
        ProjectViewModel("S1", api.id, repository, provider, InMemoryProjectPreferences(), main.dispatcher, SavedStateHandle())
            .also { advanceUntilIdle() }

    // MARK: - Lista de proyectos

    @Test
    fun `tras una lectura expone el nivel y el aviso`() = runTest(main.dispatcher) {
        ssh.memory = memory(0.15, claude = 12)
        val vm = projects()
        assertEquals(ServerMemoryPressureLevel.NORMAL, vm.state.value.memoryLevel)
        assertEquals(0, ssh.memoryReads, "cargar la lista no lee la memoria: solo el sondeo")

        vm.refreshMemory()
        assertEquals(ServerMemoryPressureLevel.HIGH, vm.state.value.memoryLevel)
        assertEquals(ServerMemoryWarning(ServerMemoryPressureLevel.HIGH, 85, 12), vm.state.value.memoryWarning)
    }

    @Test
    fun `un fallo conserva la última lectura`() = runTest(main.dispatcher) {
        ssh.memory = memory(0.05)
        val vm = projects()
        vm.refreshMemory()
        assertEquals(ServerMemoryPressureLevel.CRITICAL, vm.state.value.memoryLevel)

        ssh.memoryError = IOException("canal rechazado")
        vm.refreshMemory()
        assertEquals(ServerMemoryPressureLevel.CRITICAL, vm.state.value.memoryLevel)
        assertEquals(memory(0.05), vm.state.value.memory)
        assertNull(vm.state.value.message, "es informativo: no se avisa del fallo")
    }

    @Test
    fun `la histéresis mantiene el aviso hasta superar el 25 por ciento libre`() = runTest(main.dispatcher) {
        ssh.memory = memory(0.15)
        val vm = projects()
        vm.refreshMemory()
        ssh.memory = memory(0.22)
        vm.refreshMemory()
        assertEquals(ServerMemoryPressureLevel.HIGH, vm.state.value.memoryLevel)
        ssh.memory = memory(0.26)
        vm.refreshMemory()
        assertEquals(ServerMemoryPressureLevel.NORMAL, vm.state.value.memoryLevel)
        assertNull(vm.state.value.memoryWarning)
    }

    @Test
    fun `un servidor que no da la memoria retira el aviso`() = runTest(main.dispatcher) {
        ssh.memory = memory(0.05)
        val vm = projects()
        vm.refreshMemory()
        ssh.memory = null
        vm.refreshMemory()
        assertEquals(ServerMemoryPressureLevel.NORMAL, vm.state.value.memoryLevel)
        assertNull(vm.state.value.memoryWarning)
    }

    @Test
    fun `el sondeo relee cada intervalo solo con la lista cargada`() = runTest(main.dispatcher) {
        ssh.memory = memory(0.5)
        val vm = projects()
        val poll = launch { vm.pollMemoryWhileVisible() }
        runCurrent()
        assertEquals(1, ssh.memoryReads)
        advanceTimeBy(ProjectsViewModel.MEMORY_REFRESH_MILLIS)
        runCurrent()
        assertEquals(2, ssh.memoryReads)
        poll.cancel()
    }

    @Test
    fun `con memoria crítica arrancar un proyecto detenido pide confirmación`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        ssh.memory = memory(0.05, claude = 20)
        val vm = projects()
        vm.refreshMemory()

        vm.openProject(vm.state.value.listing.entries.single())
        val dialog = assertIs<ProjectsDialog.MemoryWarning>(vm.state.value.dialog)
        assertEquals(95, dialog.warning.usedPercent)
        assertTrue(ssh.calls.none { it.startsWith("start:") })

        vm.dismissProjectDialog()
        assertNull(vm.state.value.dialog)
        assertTrue(ssh.calls.none { it.startsWith("start:") })

        vm.events.test {
            vm.openProject(vm.state.value.listing.entries.single())
            vm.confirmStartDespiteMemory()
            advanceUntilIdle()
            assertEquals(ProjectsEvent.OpenProject(api.id), awaitItem())
        }
        assertNull(vm.state.value.dialog)
        assertEquals(1, ssh.calls.count { it.startsWith("start:") })
    }

    @Test
    fun `con memoria alta o un proyecto en marcha no se pide confirmación`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api, project(2, "web"))
        ssh.sessions = listOf(session("web"))
        ssh.memory = memory(0.15)
        val vm = projects()
        vm.refreshMemory()
        vm.openProject(vm.state.value.listing.entries.first { it.project.name == "api" })
        advanceUntilIdle()
        assertNull(vm.state.value.dialog)

        ssh.memory = memory(0.05)
        vm.refreshMemory()
        vm.openProject(vm.state.value.listing.entries.first { it.project.name == "web" })
        advanceUntilIdle()
        assertNull(vm.state.value.dialog, "abrir uno en marcha no arranca nada nuevo")
        assertEquals(2, ssh.calls.count { it.startsWith("start:") })
    }

    // MARK: - Detalle del proyecto («Arrancar» / «Iniciar de nuevo»)

    @Test
    fun `iniciar con memoria crítica espera la confirmación y luego reconecta`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        ssh.memory = memory(0.05)
        val vm = detail()
        var reconnected = 0

        vm.start(onStarted = { reconnected++ })
        advanceUntilIdle()
        assertEquals(ServerMemoryPressureLevel.CRITICAL, vm.state.value.memoryConfirmation?.level)
        assertFalse(vm.state.value.isStarting)
        assertTrue(ssh.calls.none { it.startsWith("start:") })

        vm.confirmStartDespiteMemory()
        advanceUntilIdle()
        assertNull(vm.state.value.memoryConfirmation)
        assertEquals(1, ssh.calls.count { it.startsWith("start:") })
        assertEquals(ProjectLoad.Loaded(api, isRunning = true), vm.state.value.load)
        assertEquals(1, reconnected)
    }

    @Test
    fun `cancelar el aviso no arranca nada`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        ssh.memory = memory(0.05)
        val vm = detail()
        var reconnected = 0
        vm.start(onStarted = { reconnected++ })
        advanceUntilIdle()

        vm.dismissMemoryConfirmation()
        vm.confirmStartDespiteMemory()
        advanceUntilIdle()
        assertNull(vm.state.value.memoryConfirmation)
        assertTrue(ssh.calls.none { it.startsWith("start:") })
        assertEquals(0, reconnected)
    }

    @Test
    fun `sin memoria crítica o si no se puede leer arranca sin preguntar`() = runTest(main.dispatcher) {
        ssh.projects = listOf(api)
        ssh.memory = memory(0.15)
        val vm = detail()
        vm.start()
        advanceUntilIdle()
        assertNull(vm.state.value.memoryConfirmation)
        assertEquals(1, ssh.calls.count { it.startsWith("start:") })

        ssh.memoryError = IOException("sin canal")
        vm.start()
        advanceUntilIdle()
        assertNull(vm.state.value.memoryConfirmation)
        assertEquals(2, ssh.calls.count { it.startsWith("start:") })
    }

    // MARK: - Textos

    @Test
    fun `títulos por nivel`() {
        assertEquals(UiText.res(R.string.memory_pressure_high_title), ServerMemoryWarning(ServerMemoryPressureLevel.HIGH, 85, null).titleText())
        assertEquals(UiText.res(R.string.memory_pressure_critical_title), ServerMemoryWarning(ServerMemoryPressureLevel.CRITICAL, 95, null).titleText())
    }

    @Test
    fun `el mensaje cita los procesos de Claude con plural`() {
        assertEquals(
            UiText.Plural(R.plurals.memory_pressure_message_claude, 20, listOf(95, 20)),
            ServerMemoryWarning(ServerMemoryPressureLevel.CRITICAL, 95, 20).messageText(),
        )
        assertEquals(
            UiText.Plural(R.plurals.memory_pressure_message_claude, 1, listOf(85, 1)),
            ServerMemoryWarning(ServerMemoryPressureLevel.HIGH, 85, 1).messageText(),
        )
    }

    @Test
    fun `sin procesos de Claude el mensaje no los cita`() {
        assertEquals(UiText.res(R.string.memory_pressure_message, 85), ServerMemoryWarning(ServerMemoryPressureLevel.HIGH, 85, 0).messageText())
        assertEquals(UiText.res(R.string.memory_pressure_message, 85), ServerMemoryWarning(ServerMemoryPressureLevel.HIGH, 85, null).messageText())
    }
}
