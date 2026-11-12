@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.testing.AGENT_1
import com.iaportafolio.argos.testing.AGENT_2
import com.iaportafolio.argos.testing.AgentLog
import com.iaportafolio.argos.testing.FakeConnector
import com.iaportafolio.argos.testing.InMemoryAgentWatchBackend
import com.iaportafolio.argos.testing.InMemoryClaudeTokens
import com.iaportafolio.argos.testing.InMemorySecretStore
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.RecordingAlerts
import com.iaportafolio.argos.testing.RecordingScheduler
import com.iaportafolio.argos.testing.SECRET_TOKEN
import com.iaportafolio.argos.testing.SNAPSHOTS_COMMAND
import com.iaportafolio.argos.testing.SnapshotService
import com.iaportafolio.argos.testing.networkDown
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.snapshotLine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AgentNotifierTest {

    private val dispatcher = StandardTestDispatcher()
    private val dev = server(id = "A", name = "dev", host = "dev.example.com")
    private val prod = server(id = "B", name = "prod", host = "prod.example.com")
    private val repository = InMemoryServerRepository(listOf(dev, prod))
    private val secrets = InMemorySecretStore().apply {
        write("A", SecretKind.PASSWORD, "pw-a")
        write("B", SecretKind.PASSWORD, "pw-b")
    }
    private val trust = InMemoryTrustStore(mapOf(dev.endpoint to "SHA256:a", prod.endpoint to "SHA256:b"))
    private val devService = SnapshotService(snapshotLine(title = "api", logBytes = 100))
    private val prodService = SnapshotService(snapshotLine(id = AGENT_2, title = "web", logBytes = 200))
    private val connector = FakeConnector(mapOf("A" to devService, "B" to prodService))
    private val backend = InMemoryAgentWatchBackend()
    private val store = AgentWatchStore(backend)
    private val alerts = RecordingAlerts()
    private val scheduler = RecordingScheduler()
    private val logs = mutableListOf<String>()
    private val tokens = InMemoryClaudeTokens()
    private val now = Instant.parse("2026-01-01T01:00:00Z")

    private fun notifier(watchStore: AgentWatchStore = store) = AgentNotifier(
        servers = repository,
        secrets = secrets,
        hostKeys = trust,
        connector = connector,
        tokens = tokens,
        store = watchStore,
        alerts = alerts,
        scheduler = scheduler,
        io = dispatcher,
        serverTimeoutMillis = 1_000,
        clock = { now },
        log = { logs += it },
    )

    private fun runScoped(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun AgentNotifier.watchBoth() {
        agentOpened("A")
        agentOpened("B")
    }

    // MARK: - Planificación

    @Test
    fun `revisa cada servidor apuntado y avisa con el nombre de su servidor`() = runScoped {
        val notifier = notifier().apply { watchBoth() }

        assertEquals(AgentCheckOutcome.CHECKED, notifier.check())

        assertEquals(listOf(SNAPSHOTS_COMMAND), devService.scripts)
        assertEquals(listOf(SNAPSHOTS_COMMAND), prodService.scripts)
        assertEquals(
            listOf(Triple("A", "dev", AGENT_1), Triple("B", "prod", AGENT_2)),
            alerts.posted.map { Triple(it.serverId, it.serverName, it.agentId) },
        )
        assertEquals("api: Claude terminó", alerts.posted[0].title)
        assertEquals("ok", alerts.posted[0].body)
    }

    @Test
    fun `avisa también de un permiso pendiente`() = runScoped {
        devService.output = snapshotLine(tail = AgentLog.permission("r1", tool = "Bash"))
        val notifier = notifier().apply { agentOpened("A") }

        notifier.check()

        assertEquals("api: Claude espera tu permiso", alerts.posted.single().title)
    }

    @Test
    fun `no revisa los servidores sin apuntar`() = runScoped {
        val notifier = notifier().apply { agentOpened("A") }
        notifier.check()
        assertEquals(listOf("A"), connector.opened)
    }

    @Test
    fun `sin servidores apuntados no abre ninguna conexión`() = runScoped {
        assertEquals(AgentCheckOutcome.CHECKED, notifier().check())
        assertTrue(connector.opened.isEmpty())
    }

    // MARK: - Lo ya visto

    @Test
    fun `lo avisado se persiste y no se repite aunque se reinicie el proceso`() = runScoped {
        notifier().apply { agentOpened("A") }.check()
        assertEquals(1, alerts.posted.size)

        notifier(AgentWatchStore(backend)).check()

        assertEquals(1, alerts.posted.size)
        assertEquals(mapOf(AGENT_1 to 100L), AgentWatchStore(backend).seenBytes("A"))
    }

    @Test
    fun `avisa de nuevo cuando el log crece`() = runScoped {
        val notifier = notifier().apply { agentOpened("A") }
        notifier.check()
        devService.output = snapshotLine(logBytes = 150)
        notifier.check()
        assertEquals(2, alerts.posted.size)
    }

    @Test
    fun `lo leído en el chat no se avisa y nunca retrocede`() = runScoped {
        val notifier = notifier().apply { agentOpened("A") }
        notifier.chatShown("A", AGENT_1)
        notifier.chatHidden("A", AGENT_1, 100)
        notifier.chatShown("A", AGENT_1)
        notifier.chatHidden("A", AGENT_1, 40)
        assertEquals(100L, store.seenBytes("A")[AGENT_1])

        notifier.check()

        assertTrue(alerts.posted.isEmpty())
    }

    @Test
    fun `una comprobación no pisa lo que marcó el chat mientras tanto`() = runScoped {
        val gate = CompletableDeferred<Unit>()
        devService.gate = gate
        val notifier = notifier().apply { agentOpened("A") }
        val check = launch { notifier.check() }
        runCurrent()

        notifier.chatHidden("A", AGENT_1, 500)
        gate.complete(Unit)
        check.join()

        assertEquals(500L, store.seenBytes("A")[AGENT_1])
    }

    @Test
    fun `olvida lo visto de los agentes que ya no existen`() = runScoped {
        val notifier = notifier().apply { agentOpened("A") }
        notifier.check()
        devService.output = snapshotLine(id = AGENT_2, title = "web")
        notifier.check()
        assertEquals(setOf(AGENT_2), store.seenBytes("A").keys)
    }

    // MARK: - Chat abierto

    @Test
    fun `no avisa del chat a la vista pero sí de los demás y lo da por visto`() = runScoped {
        devService.output = snapshotLine(id = AGENT_1) + snapshotLine(id = AGENT_2, title = "web")
        val notifier = notifier().apply { agentOpened("A") }
        notifier.chatShown("A", AGENT_1)

        notifier.check()

        assertEquals(listOf(AGENT_2), alerts.posted.map { it.agentId })
        assertEquals(100L, store.seenBytes("A")[AGENT_1])
    }

    @Test
    fun `al salir del chat vuelve a avisar de lo nuevo`() = runScoped {
        val notifier = notifier().apply { agentOpened("A") }
        notifier.chatShown("A", AGENT_1)
        notifier.chatHidden("A", AGENT_1, 100)
        devService.output = snapshotLine(logBytes = 300)

        notifier.check()

        assertEquals(listOf(AGENT_1), alerts.posted.map { it.agentId })
    }

    @Test
    fun `abrir el chat retira su aviso`() {
        val notifier = notifier()
        notifier.chatShown("A", AGENT_1)
        assertEquals(listOf("A" to AGENT_1), alerts.cancelled)
    }

    // MARK: - Fallos aislados

    @Test
    fun `un servidor sin red no afecta a los demás y se desconecta`() = runScoped {
        devService.error = networkDown()
        val notifier = notifier().apply { watchBoth() }

        assertEquals(AgentCheckOutcome.CHECKED, notifier.check())

        assertEquals(listOf("B"), alerts.posted.map { it.serverId })
        assertEquals(1, devService.disconnects)
        assertEquals(1, prodService.disconnects)
        assertTrue(store.seenBytes("A").isEmpty())
    }

    @Test
    fun `un servidor sin credenciales no afecta a los demás`() = runScoped {
        secrets.delete("A", SecretKind.PASSWORD)
        val notifier = notifier().apply { watchBoth() }

        notifier.check()

        assertEquals(listOf("B"), connector.opened)
        assertEquals(listOf("B"), alerts.posted.map { it.serverId })
    }

    @Test
    fun `una host key cambiada no afecta a los demás ni toca las huellas`() = runScoped {
        devService.error = HostKeyMismatchException(dev.endpoint, "SHA256:a", "SHA256:otra")
        val before = trust.known.toMap()
        val notifier = notifier().apply { watchBoth() }

        notifier.check()

        assertEquals(before, trust.known)
        assertEquals(listOf("B"), alerts.posted.map { it.serverId })
    }

    @Test
    fun `un servidor colgado agota su tiempo, se desconecta y sigue con los demás`() = runScoped {
        devService.gate = CompletableDeferred()
        val notifier = notifier().apply { watchBoth() }
        val check = launch { notifier.check() }
        runCurrent()
        assertTrue(alerts.posted.isEmpty())

        advanceTimeBy(1_001)
        runCurrent()
        check.join()

        assertEquals(1, devService.disconnects)
        assertEquals(listOf("B"), alerts.posted.map { it.serverId })
    }

    // MARK: - Desconexión

    @Test
    fun `desconecta siempre al terminar bien`() = runScoped {
        notifier().apply { agentOpened("A") }.check()
        assertEquals(1, devService.disconnects)
    }

    @Test
    fun `desconecta aunque se cancele la comprobación`() = runScoped {
        devService.gate = CompletableDeferred()
        val notifier = notifier().apply { agentOpened("A") }
        val check = launch { notifier.check() }
        runCurrent()

        check.cancelAndJoin()

        assertEquals(1, devService.disconnects)
        assertTrue(alerts.posted.isEmpty())
    }

    @Test
    fun `tras cancelar se puede volver a comprobar`() = runScoped {
        devService.gate = CompletableDeferred()
        val notifier = notifier().apply { agentOpened("A") }
        val check = launch { notifier.check() }
        runCurrent()
        check.cancelAndJoin()

        devService.gate = null
        assertEquals(AgentCheckOutcome.CHECKED, notifier.check())
        assertEquals(1, alerts.posted.size)
    }

    // MARK: - Solapes

    @Test
    fun `dos comprobaciones no se solapan`() = runScoped {
        val gate = CompletableDeferred<Unit>()
        devService.gate = gate
        val notifier = notifier().apply { agentOpened("A") }
        val first = launch { notifier.check() }
        runCurrent()

        assertEquals(AgentCheckOutcome.BUSY, notifier.check())
        assertEquals(listOf("A"), connector.opened)

        gate.complete(Unit)
        first.join()
        assertEquals(1, alerts.posted.size)
    }

    // MARK: - Huellas

    @Test
    fun `un endpoint sin huella se salta sin conectar ni confiar en nada`() = runScoped {
        trust.forget(dev.endpoint)
        val notifier = notifier().apply { watchBoth() }

        notifier.check()

        assertEquals(listOf("B"), connector.opened)
        assertEquals(mapOf(prod.endpoint to "SHA256:b"), trust.known)
        assertEquals(listOf("B"), alerts.posted.map { it.serverId })
    }

    @Test
    fun `el conector recibe un almacén que no confía en huellas nuevas`() = runScoped {
        notifier().apply { agentOpened("A") }.check()

        val handed = connector.trustStores.single()
        assertEquals("SHA256:a", handed.trustedFingerprint(dev.endpoint))
        runCatching { handed.trust("nuevo.example.com:22", "SHA256:x") }
            .onSuccess { error("Confiar debe abortar: si vuelve con normalidad, el verificador acepta la clave") }
        runCatching { handed.trust(dev.endpoint, "SHA256:otra") }
        handed.forget(dev.endpoint)
        assertEquals(mapOf(dev.endpoint to "SHA256:a", prod.endpoint to "SHA256:b"), trust.known)
    }

    // MARK: - Secretos

    @Test
    fun `pasa título y cuerpo por el redactor`() = runScoped {
        tokens.token = "token-exacto-sin-forma"
        val bigResult = """{"type":"result","subtype":"success","is_error":false,"result":"clave $SECRET_TOKEN y token-exacto-sin-forma"}"""
        devService.output = snapshotLine(title = "api $SECRET_TOKEN", tail = bigResult)
        val notifier = notifier().apply { agentOpened("A") }

        notifier.check()

        val alert = alerts.posted.single()
        assertFalse(SECRET_TOKEN in alert.title)
        assertFalse(SECRET_TOKEN in alert.body)
        assertFalse("token-exacto-sin-forma" in alert.body)
        assertEquals("clave •••• y ••••", alert.body)
    }

    @Test
    fun `sin poder leer el token sigue tapando lo que tenga su forma`() = runScoped {
        tokens.readError = IllegalStateException("Keystore")
        val result = """{"type":"result","subtype":"success","is_error":false,"result":"$SECRET_TOKEN"}"""
        devService.output = snapshotLine(tail = result)
        val notifier = notifier().apply { agentOpened("A") }

        notifier.check()

        assertEquals("••••", alerts.posted.single().body)
    }

    @Test
    fun `los registros no llevan secretos ni contenido del servidor`() = runScoped {
        tokens.token = SECRET_TOKEN
        devService.error = IllegalStateException("stderr remoto $SECRET_TOKEN conversación privada")
        val notifier = notifier().apply { agentOpened("A") }

        notifier.check()

        assertEquals(1, logs.size)
        assertTrue("IllegalStateException" in logs.single())
        assertFalse(SECRET_TOKEN in logs.single())
        assertFalse("conversación" in logs.single())
        assertFalse("pw-a" in logs.single())
    }

    // MARK: - Apuntar, quitar y ajustes

    @Test
    fun `apuntar programa el trabajo y persiste el servidor`() {
        notifier().agentOpened("A")
        assertEquals(1, scheduler.scheduled)
        assertEquals(setOf("A"), AgentWatchStore(backend).watchedServers())
    }

    @Test
    fun `quitar el último servidor cancela el trabajo y limpia su estado`() = runScoped {
        val notifier = notifier().apply { watchBoth() }
        notifier.check()

        notifier.serverDeleted("A")
        assertEquals(0, scheduler.cancelled)
        assertTrue(store.seenBytes("A").isEmpty())
        assertEquals(listOf("A" to AGENT_1), alerts.cancelled)

        notifier.serverDeleted("B")
        assertEquals(1, scheduler.cancelled)
        assertTrue(store.watchedServers().isEmpty())
    }

    @Test
    fun `un servidor apuntado que ya no existe se limpia al comprobar`() = runScoped {
        val notifier = notifier().apply { watchBoth() }
        repository.delete("A")

        notifier.check()

        assertEquals(setOf("B"), store.watchedServers())
        assertEquals(listOf("B"), connector.opened)
    }

    @Test
    fun `desactivar cancela el trabajo y la comprobación no conecta`() = runScoped {
        val notifier = notifier().apply { agentOpened("A") }

        notifier.setNotificationsEnabled(false)

        assertEquals(1, scheduler.cancelled)
        assertEquals(AgentCheckOutcome.DISABLED, notifier.check())
        assertTrue(connector.opened.isEmpty())
    }

    @Test
    fun `apuntar con los avisos desactivados no programa nada`() {
        val notifier = notifier()
        notifier.setNotificationsEnabled(false)
        notifier.agentOpened("A")
        assertEquals(0, scheduler.scheduled)
    }

    @Test
    fun `reactivar programa de nuevo solo si hay servidores`() {
        val notifier = notifier()
        notifier.setNotificationsEnabled(false)
        notifier.setNotificationsEnabled(true)
        assertEquals(0, scheduler.scheduled)

        notifier.agentOpened("A")
        notifier.setNotificationsEnabled(false)
        notifier.setNotificationsEnabled(true)
        assertEquals(2, scheduler.scheduled)
    }

    @Test
    fun `con las notificaciones bloqueadas por el sistema no conecta`() = runScoped {
        alerts.allowed = false
        val notifier = notifier().apply { agentOpened("A") }

        assertEquals(AgentCheckOutcome.BLOCKED, notifier.check())

        assertTrue(connector.opened.isEmpty())
    }

    @Test
    fun `sin agentes en marcha deja de revisar el servidor, sin olvidar lo visto`() = runScoped {
        val notifier = notifier().apply { watchBoth() }
        devService.output = snapshotLine(title = "api", logBytes = 100).replaceFirst("|1|", "|0|")

        notifier.check()

        // El último resultado sí se avisa; después ya no se abre conexión con ese servidor.
        assertEquals(listOf("A", "B"), alerts.posted.map { it.serverId })
        assertEquals(setOf("B"), store.watchedServers())
        assertEquals(mapOf(AGENT_1 to 100L), store.seenBytes("A"))
        notifier.check()
        assertEquals(1, devService.scripts.size)
        assertEquals(2, prodService.scripts.size)
        assertEquals(0, scheduler.cancelled)

        // Al reanudarlo se vuelve a revisar, y lo ya avisado no se repite.
        notifier.agentOpened("A")
        devService.output = snapshotLine(title = "api", logBytes = 100)
        notifier.check()
        assertEquals(2, devService.scripts.size)
        assertEquals(2, alerts.posted.size)
    }

    @Test
    fun `si ningún servidor tiene agentes en marcha se cancela el trabajo periódico`() = runScoped {
        val notifier = notifier().apply { agentOpened("A") }
        devService.output = ""

        notifier.check()

        assertTrue(store.watchedServers().isEmpty())
        assertEquals(1, scheduler.cancelled)
    }

    @Test
    fun `el terminal pide el permiso aunque los avisos de agentes estén desactivados`() {
        val notifier = notifier()
        notifier.setNotificationsEnabled(false)
        assertFalse(notifier.claimPermissionRequest(alreadyGranted = true, forTerminal = true))
        assertTrue(notifier.claimPermissionRequest(alreadyGranted = false, forTerminal = true))
        assertFalse(notifier.claimPermissionRequest(alreadyGranted = false, forTerminal = true))
    }

    // MARK: - Permiso de notificaciones

    @Test
    fun `el permiso se pide una sola vez aunque se reinicie el proceso`() {
        val notifier = notifier()
        assertTrue(notifier.claimPermissionRequest(alreadyGranted = false))
        assertFalse(notifier.claimPermissionRequest(alreadyGranted = false))
        assertFalse(notifier(AgentWatchStore(backend)).claimPermissionRequest(alreadyGranted = false))
    }

    @Test
    fun `el permiso no se pide si ya está concedido o con los avisos desactivados`() {
        val notifier = notifier()
        assertFalse(notifier.claimPermissionRequest(alreadyGranted = true))
        notifier.setNotificationsEnabled(false)
        assertFalse(notifier.claimPermissionRequest(alreadyGranted = false))
        notifier.setNotificationsEnabled(true)
        assertTrue(notifier.claimPermissionRequest(alreadyGranted = false))
    }

    @Test
    fun `runEvery espera antes de la primera vez y se detiene al cancelar`() = runScoped {
        var runs = 0
        val loop = launch { runEvery(60_000) { runs++ } }
        runCurrent()
        assertEquals(0, runs)
        advanceTimeBy(60_001)
        assertEquals(1, runs)
        advanceTimeBy(60_000)
        assertEquals(2, runs)
        loop.cancelAndJoin()
        advanceTimeBy(600_000)
        assertEquals(2, runs)
    }

}
