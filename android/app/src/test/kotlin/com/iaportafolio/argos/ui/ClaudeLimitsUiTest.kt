@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.usage.ClaudeLimitWindow
import com.iaportafolio.argos.core.usage.ClaudeLimitsInstallState
import com.iaportafolio.argos.core.usage.ClaudeLimitsLevel
import com.iaportafolio.argos.core.usage.ClaudeLimitsReading
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryProjectPreferences
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.claude.ClaudeLimitsSetup
import com.iaportafolio.argos.ui.claude.ClaudeLimitsViewModel
import com.iaportafolio.argos.ui.common.UiText
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
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Límites de uso de Claude: línea/aviso de la lista de proyectos y pantalla de activación. */
class ClaudeLimitsUiTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository(listOf(server()))
    private val provider = FakeServiceProvider()
    private val ssh get() = provider.service
    private val now = Instant.ofEpochSecond(1_800_000_000)

    private fun reading(percent: Double, resetIn: Long = 3_600) = ClaudeLimitsReading.of(
        listOf(
            ClaudeLimitWindow("seven_day", 10.0, now.plusSeconds(86_400)),
            ClaudeLimitWindow("five_hour", percent, now.plusSeconds(resetIn)),
        ),
        now,
    )

    private fun TestScope.projects(): ProjectsViewModel =
        ProjectsViewModel(
            "S1", repository, provider, InMemoryTrustStore(), InMemoryProjectPreferences(), main.dispatcher,
            clock = { now },
        ).also { advanceUntilIdle() }

    private fun TestScope.limitsScreen(): ClaudeLimitsViewModel =
        ClaudeLimitsViewModel("S1", repository, provider, main.dispatcher, clock = { now }).also { advanceUntilIdle() }

    // MARK: - Lista de proyectos

    @Test
    fun `tras una lectura la lista expone los limites ordenados`() = runTest(main.dispatcher) {
        ssh.limits = reading(42.0)
        val vm = projects()
        assertNull(vm.state.value.claudeLimits)
        assertEquals(0, ssh.limitsReads, "cargar la lista no lee los límites: solo el sondeo")

        vm.refreshClaudeLimits()
        val limits = assertNotNull(vm.state.value.claudeLimits)
        assertEquals(listOf("five_hour", "seven_day"), limits.reading.windows.map { it.kind })
        assertEquals(ClaudeLimitsLevel.NORMAL, limits.level)
        assertEquals(42, limits.worstPercent)
    }

    @Test
    fun `un fallo conserva la ultima lectura y sin datos se retira`() = runTest(main.dispatcher) {
        ssh.limits = reading(90.0)
        val vm = projects()
        vm.refreshClaudeLimits()
        assertEquals(ClaudeLimitsLevel.HIGH, vm.state.value.claudeLimits?.level)

        ssh.limitsError = IOException("canal rechazado")
        vm.refreshClaudeLimits()
        assertEquals(ClaudeLimitsLevel.HIGH, vm.state.value.claudeLimits?.level)
        assertNull(vm.state.value.message, "es informativo: no se avisa del fallo")

        ssh.limitsError = null
        ssh.limits = null
        vm.refreshClaudeLimits()
        assertNull(vm.state.value.claudeLimits)
    }

    @Test
    fun `avisa al cruzar el umbral una sola vez por ventana`() = runTest(main.dispatcher) {
        val vm = projects()
        assertTrue(vm.absorbLimits(reading(40.0)).isEmpty())
        assertEquals(listOf(ClaudeLimitsLevel.HIGH), vm.absorbLimits(reading(88.0)).map { it.level })
        assertTrue(vm.absorbLimits(reading(89.0)).isEmpty())
        assertTrue(vm.absorbLimits(reading(60.0)).isEmpty(), "un dato viejo de otra sesión no baja el uso")
        assertEquals(89, vm.state.value.claudeLimits?.worstPercent)
        assertEquals(listOf(ClaudeLimitsLevel.CRITICAL), vm.absorbLimits(reading(96.0)).map { it.level })
        assertTrue(vm.absorbLimits(null).isEmpty())
        assertNull(vm.state.value.claudeLimits)
    }

    @Test
    fun `el sondeo de la lista relee memoria y limites cada intervalo`() = runTest(main.dispatcher) {
        val vm = projects()
        val poll = launch { vm.pollServerReadingsWhileVisible() }
        runCurrent()
        assertEquals(1, ssh.limitsReads)
        assertEquals(1, ssh.memoryReads)
        advanceTimeBy(ProjectsViewModel.MEMORY_REFRESH_MILLIS)
        runCurrent()
        assertEquals(2, ssh.limitsReads)
        poll.cancel()
    }

    // MARK: - Pantalla «Límites de Claude»

    @Test
    fun `activar y quitar cambian el estado`() = runTest(main.dispatcher) {
        val vm = limitsScreen()
        vm.refresh()
        advanceUntilIdle()
        assertEquals(ClaudeLimitsSetup.Inactive, vm.state.value.setup)
        assertEquals(0, ssh.limitsReads, "sin statusline no se leen los límites")

        vm.activate()
        advanceUntilIdle()
        assertEquals(ClaudeLimitsSetup.Active, vm.state.value.setup)
        assertEquals(ClaudeLimitsInstallState.Active, ssh.limitsState)
        assertEquals(UiText.res(R.string.claude_limits_activated), vm.state.value.notice)
        assertFalse(vm.state.value.isWorking)

        vm.deactivate()
        advanceUntilIdle()
        assertEquals(ClaudeLimitsSetup.Inactive, vm.state.value.setup)
        assertEquals(ClaudeLimitsInstallState.Inactive, ssh.limitsState)
        assertEquals(listOf("installLimits", "uninstallLimits"), ssh.calls.filter { it.endsWith("Limits") })
    }

    @Test
    fun `activa relee y ensena los medidores`() = runTest(main.dispatcher) {
        ssh.limitsState = ClaudeLimitsInstallState.Active
        ssh.limits = reading(97.0)
        val vm = limitsScreen()
        vm.refresh()
        advanceUntilIdle()
        assertEquals(ClaudeLimitsSetup.Active, vm.state.value.setup)
        assertEquals(ClaudeLimitsLevel.CRITICAL, vm.state.value.status?.level)
    }

    @Test
    fun `un fallo al comprobar o activar se ensena`() = runTest(main.dispatcher) {
        ssh.limitsError = IOException("sin red")
        val vm = limitsScreen()
        vm.refresh()
        advanceUntilIdle()
        assertIs<ClaudeLimitsSetup.Failed>(vm.state.value.setup)

        vm.activate()
        advanceUntilIdle()
        val notice = assertIs<UiText.Resource>(vm.state.value.notice)
        assertEquals(R.string.claude_limits_activate_failed, notice.id)
        assertEquals(ClaudeLimitsInstallState.Inactive, ssh.limitsState)
    }

    @Test
    fun `sin la copia del anterior ofrece reparar y quitar se niega`() = runTest(main.dispatcher) {
        ssh.limitsState = ClaudeLimitsInstallState.NeedsRepair(previousMissing = true)
        ssh.limits = reading(30.0)
        val vm = limitsScreen()
        vm.refresh()
        advanceUntilIdle()
        assertEquals(ClaudeLimitsSetup.NeedsRepair(previousMissing = true), vm.state.value.setup)
        assertEquals(30, vm.state.value.status?.worstPercent, "puesta aunque incompleta: los límites se leen")

        vm.deactivate()
        advanceUntilIdle()
        assertEquals(R.string.claude_limits_remove_failed, assertIs<UiText.Resource>(vm.state.value.notice).id)
        assertEquals(ClaudeLimitsSetup.NeedsRepair(previousMissing = true), vm.state.value.setup)

        // Reparar no recupera la copia perdida: sigue pidiendo reparar.
        vm.activate()
        advanceUntilIdle()
        assertEquals(ClaudeLimitsSetup.NeedsRepair(previousMissing = true), vm.state.value.setup)
    }

    @Test
    fun `reparar una version vieja la deja activa`() = runTest(main.dispatcher) {
        ssh.limitsState = ClaudeLimitsInstallState.NeedsRepair(previousMissing = false)
        val vm = limitsScreen()
        vm.refresh()
        advanceUntilIdle()
        vm.activate()
        advanceUntilIdle()
        assertEquals(ClaudeLimitsSetup.Active, vm.state.value.setup)
        assertEquals(UiText.res(R.string.claude_limits_activated), vm.state.value.notice)
    }
}
