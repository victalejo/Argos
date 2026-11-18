@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.data.LocalNetworkGate
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.testing.AGENT_2
import com.iaportafolio.argos.testing.FakeConnector
import com.iaportafolio.argos.testing.InMemoryAgentWatchBackend
import com.iaportafolio.argos.testing.InMemoryClaudeTokens
import com.iaportafolio.argos.testing.InMemorySecretStore
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.RecordingAlerts
import com.iaportafolio.argos.testing.RecordingScheduler
import com.iaportafolio.argos.testing.SNAPSHOTS_COMMAND
import com.iaportafolio.argos.testing.SnapshotService
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.snapshotLine
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Conexión reutilizada, red local de Android 17 y diagnóstico del notificador. */
class AgentNotifierConnectionsTest {

    private val dispatcher = StandardTestDispatcher()
    private val dev = server(id = "A", name = "dev", host = "dev.example.com")
    private val nas = server(id = "B", name = "nas", host = "192.168.1.30")
    private val repository = InMemoryServerRepository(listOf(dev, nas))
    private val secrets = InMemorySecretStore().apply {
        write("A", SecretKind.PASSWORD, "pw-a")
        write("B", SecretKind.PASSWORD, "pw-b")
    }
    private val trust = InMemoryTrustStore(mapOf(dev.endpoint to "SHA256:a", nas.endpoint to "SHA256:b"))
    private val devService = SnapshotService(snapshotLine(title = "api", logBytes = 100))
    private val nasService = SnapshotService(snapshotLine(id = AGENT_2, title = "web", logBytes = 200))
    private val connector = FakeConnector(mapOf("A" to devService, "B" to nasService))
    private val alerts = RecordingAlerts()
    private val backend = InMemoryAgentWatchBackend()
    private val diagnostics = BackgroundDiagnosticsStore(backend)
    private val now = Instant.parse("2026-11-18T12:00:00Z")
    private var live: Map<String, SSHServicing> = emptyMap()
    private var granted = false

    private fun notifier() = AgentNotifier(
        servers = repository,
        secrets = secrets,
        hostKeys = trust,
        connector = connector,
        tokens = InMemoryClaudeTokens(),
        store = AgentWatchStore(backend),
        alerts = alerts,
        scheduler = RecordingScheduler(),
        io = dispatcher,
        serverTimeoutMillis = 1_000,
        clock = { now },
        log = {},
        live = { server: Server -> live[server.id] },
        localNetwork = LocalNetworkGate({ true }, { granted }) { emptyList() },
        diagnostics = diagnostics,
    ).apply {
        agentOpened("A")
        agentOpened("B")
    }

    @Test
    fun `sin permiso de red local salta el servidor de la Wi-Fi sin darlo por caído`() = runTest(dispatcher) {
        assertEquals(AgentCheckOutcome.CHECKED, notifier().check())

        assertEquals(listOf("A"), connector.opened)
        assertTrue(nasService.scripts.isEmpty())
        val record = diagnostics.lastCheck.value
        assertEquals(1, record?.count(ServerCheckResult.CHECKED))
        assertEquals(1, record?.count(ServerCheckResult.LOCAL_NETWORK_BLOCKED))
        assertEquals(0, record?.count(ServerCheckResult.FAILED))
        assertEquals(CheckTrigger.BACKGROUND, record?.trigger)
        assertEquals(now, record?.at)

        granted = true
        notifier().check(CheckTrigger.MANUAL)
        assertEquals(listOf("A", "A", "B"), connector.opened)
    }

    @Test
    fun `reutiliza la conexión abierta de la app y no la cierra`() = runTest(dispatcher) {
        granted = true
        val shared = SnapshotService(snapshotLine(title = "api", logBytes = 100))
        live = mapOf("A" to shared)

        notifier().check(CheckTrigger.FOREGROUND)

        assertEquals(listOf(SNAPSHOTS_COMMAND), shared.scripts)
        assertEquals(0, shared.disconnects)
        assertEquals(listOf("B"), connector.opened)
        assertEquals(1, nasService.disconnects)
    }

    @Test
    fun `liveOnly solo revisa lo ya conectado y sin nada no ensucia el diagnóstico`() = runTest(dispatcher) {
        granted = true
        notifier().check(CheckTrigger.FOREGROUND, liveOnly = true)
        assertTrue(connector.opened.isEmpty())
        assertNull(diagnostics.lastCheck.value)

        val shared = SnapshotService(snapshotLine(title = "api", logBytes = 100))
        live = mapOf("A" to shared)
        notifier().check(CheckTrigger.FOREGROUND, liveOnly = true)
        assertTrue(connector.opened.isEmpty())
        assertEquals(1, shared.scripts.size)
        assertEquals(1, diagnostics.lastCheck.value?.count(ServerCheckResult.CHECKED))
    }

    @Test
    fun `un servidor que no responde queda como sin respuesta`() = runTest(dispatcher) {
        granted = true
        devService.gate = kotlinx.coroutines.CompletableDeferred()
        notifier().check()
        assertEquals(1, diagnostics.lastCheck.value?.count(ServerCheckResult.NO_RESPONSE))
        assertEquals(1, diagnostics.lastCheck.value?.count(ServerCheckResult.CHECKED))
    }
}
