@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.background

import com.iaportafolio.argos.testing.RecordingScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AppVisibilityCoordinatorTest {

    private class FakeConnections : SharedConnections {
        val probes = mutableListOf<Long>()
        var closes = 0

        override suspend fun probeAll(timeoutMillis: Long): Set<String> {
            probes += timeoutMillis
            return emptySet()
        }

        override suspend fun closeAll() {
            closes++
        }
    }

    private val connections = FakeConnections()
    private val checks = mutableListOf<Boolean>()
    private var visibleCalls = 0
    private var keepingAlive = false

    private fun TestScope.coordinator() = AppVisibilityCoordinator(
        scope = backgroundScope,
        connections = connections,
        checkAgents = { full -> checks += full },
        onVisible = { visibleCalls++ },
        isKeepingAlive = { keepingAlive },
        clock = { testScheduler.currentTime },
    ).also {
        it.start()
        runCurrent()
    }

    @Test
    fun `a la vista revisa todo al volver y después cada minuto solo lo abierto`() = runTest {
        val coordinator = coordinator()
        coordinator.onAppStarted()
        runCurrent()
        assertEquals(listOf(true), checks)
        assertEquals(1, visibleCalls)
        // Primer arranque: no venía de segundo plano, nada que comprobar.
        assertTrue(connections.probes.isEmpty())

        advanceTimeBy(60_001)
        advanceTimeBy(60_000)
        assertEquals(listOf(true, false, false), checks)
    }

    @Test
    fun `al volver de segundo plano comprueba las conexiones con plazo corto`() = runTest {
        val coordinator = coordinator()
        coordinator.onAppStarted()
        runCurrent()
        coordinator.onAppStopped()
        advanceTimeBy(10_000)
        coordinator.onAppStarted()
        runCurrent()
        assertEquals(listOf(4_000L), connections.probes)
        assertEquals(0, connections.closes)
    }

    @Test
    fun `una pausa breve no comprueba las conexiones`() = runTest {
        val coordinator = coordinator()
        coordinator.onAppStarted()
        runCurrent()
        coordinator.onAppStopped()
        advanceTimeBy(1_000)
        coordinator.onAppStarted()
        runCurrent()
        assertTrue(connections.probes.isEmpty())
    }

    @Test
    fun `oculta sin servicio ni túneles cierra a los 60 s, y no si vuelve antes`() = runTest {
        val coordinator = coordinator()
        coordinator.onAppStarted()
        runCurrent()
        coordinator.onAppStopped()
        advanceTimeBy(30_000)
        coordinator.onAppStarted()
        runCurrent()
        advanceTimeBy(60_000)
        assertEquals(0, connections.closes)

        coordinator.onAppStopped()
        advanceTimeBy(60_001)
        assertEquals(1, connections.closes)
        // Oculta no se revisan agentes.
        val before = checks.size
        advanceTimeBy(180_000)
        assertEquals(before, checks.size)
        assertFalse(coordinator.visible.value)
    }

    @Test
    fun `con servicio en primer plano o túneles no cierra nada`() = runTest {
        keepingAlive = true
        val coordinator = coordinator()
        coordinator.onAppStarted()
        runCurrent()
        coordinator.onAppStopped()
        advanceTimeBy(120_000)
        assertEquals(0, connections.closes)
    }

    @Test
    fun `cambios de red`() {
        val tracker = NetworkChangeTracker()
        assertFalse(tracker.onAvailable(1)) // red inicial al registrarse
        assertFalse(tracker.onAvailable(1))
        assertTrue(tracker.onAvailable(2)) // Wi-Fi → datos
        tracker.onLost(1) // una que ya no era la actual: nada
        assertFalse(tracker.onAvailable(2))
        tracker.onLost(2)
        assertTrue(tracker.onAvailable(2)) // vuelve tras perderla: los sockets murieron
    }

    @Test
    fun `un solo trabajo para agentes y CI`() {
        val work = RecordingScheduler()
        var agents = false
        var ci = false
        val schedule = BackgroundCheckSchedule(work, listOf({ agents }, { ci }))

        schedule.sync()
        assertEquals(0 to 1, work.scheduled to work.cancelled)
        ci = true
        schedule.asScheduler.cancel() // el notificador ya no vigila nada, pero el CI sí
        assertEquals(1 to 1, work.scheduled to work.cancelled)
        ci = false
        agents = true
        schedule.asScheduler.schedule()
        agents = false
        schedule.sync()
        assertEquals(2 to 2, work.scheduled to work.cancelled)
    }
}
