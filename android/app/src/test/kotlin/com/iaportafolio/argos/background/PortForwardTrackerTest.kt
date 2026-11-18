@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.testing.FakeKeepAliveHost
import com.iaportafolio.argos.testing.FakePortForwardService
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.server
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PortForwardTrackerTest {

    /** Solo devuelve servicios «ya abiertos»: el rastreador nunca debe abrir uno. */
    private class CachedOnly(val open: MutableMap<String, SSHServicing>) : ServiceProvider {
        override suspend fun service(server: Server): SSHServicing = error("no debe abrir conexiones")
        override suspend fun invalidate(serverId: String) = Unit
        override fun cached(server: Server): SSHServicing? = open[server.id]
    }

    private val dispatcher = StandardTestDispatcher()
    private val host = FakeKeepAliveHost()
    private val registry = ActiveTerminalRegistry(host) { true }
    private val ports = FakePortForwardService()
    private val open = mutableMapOf<String, SSHServicing>("S1" to ports)
    private val tracker = PortForwardTracker(registry, InMemoryServerRepository(listOf(server())), CachedOnly(open), dispatcher)

    @Test
    fun `refreshAll baja la cuenta cuando el cierre automático cierra un túnel`() = runTest(dispatcher) {
        val first = ports.startPortForward(3000, "localhost", 3000)
        ports.startPortForward(5173, "localhost", 5173)
        tracker.report("S1", ports.activePortForwards())
        assertEquals(2, registry.tunnelCount.value)
        assertEquals(1, host.starts)

        ports.stopPortForward(first.id)
        tracker.refreshAll()
        assertEquals(1, registry.tunnelCount.value)
    }

    @Test
    fun `sin conexión abierta sus túneles ya no cuentan`() = runTest(dispatcher) {
        tracker.report("S1", listOf(ports.startPortForward(3000, "localhost", 3000)))
        open.clear()
        tracker.refreshAll()
        assertEquals(0, registry.tunnelCount.value)
        assertTrue(registry.tunnelServers().isEmpty())
    }

    @Test
    fun `closeAll cierra los túneles y la cuenta queda a cero`() = runTest(dispatcher) {
        ports.startPortForward(3000, "localhost", 3000)
        ports.startPortForward(8080, "localhost", 8080)
        tracker.report("S1", ports.activePortForwards())

        tracker.closeAll()

        assertTrue(ports.forwards.isEmpty())
        assertEquals(0, registry.tunnelCount.value)
    }

    @Test
    fun `al desconectarse el servidor se olvidan sus túneles`() {
        registry.setTunnels("S1", 2)
        tracker.serverDisconnected("S1")
        assertEquals(0, registry.tunnelCount.value)
    }
}
