package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.monitor.CpuTicks
import com.iaportafolio.argos.core.monitor.ResourceUsage
import com.iaportafolio.argos.core.monitor.ServerResourceReading
import com.iaportafolio.argos.core.monitor.ServerResourceSample
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.monitor.ResourceMonitorViewModel
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class ResourceMonitorViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private class MonitoredService : FakeSSHService(), ServerResourceReading {
        val samples = ArrayDeque<ServerResourceSample>()
        var error: Exception? = null

        override suspend fun resourceSample(): ServerResourceSample {
            error?.let { throw it }
            return samples.removeFirst()
        }
    }

    private fun sample(total: Long, idle: Long) = ServerResourceSample(
        load1 = 0.5, load5 = 0.4, load15 = 0.3, cpu = CpuTicks(total, idle), cores = 4,
        memory = ResourceUsage(512, 1024), swap = ResourceUsage(0, 0), disk = ResourceUsage(10, 100),
        uptimeSeconds = 3_600, topProcesses = emptyList(),
    )

    @Test
    fun `la CPU sale de dos muestras y un fallo conserva la anterior`() = runTest(main.dispatcher) {
        val service = MonitoredService().apply { samples += sample(1_000, 800); samples += sample(2_000, 1_300) }
        val vm = ResourceMonitorViewModel("S1", InMemoryServerRepository(listOf(server())), FakeServiceProvider(service), main.dispatcher)

        vm.refreshOnce()
        assertNotNull(vm.state.value.sample)
        assertNull(vm.state.value.cpuUsage)
        vm.refreshOnce()
        assertEquals(0.5, vm.state.value.cpuUsage)

        service.error = java.io.IOException("caído")
        vm.refreshOnce()
        assertEquals(2_000, vm.state.value.sample?.cpu?.total)
        assertNotNull(vm.state.value.error)
    }
}
