@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.core.status.ClaudeActivitySnapshot
import com.iaportafolio.argos.core.status.ClaudeTransition
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryAgentWatchBackend
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.server
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RecordingClaudeAlerts(var allowed: Boolean = true) : ClaudeAlertSink {
    val posted = mutableListOf<ClaudeAlert>()
    val cancelled = mutableListOf<Triple<String, String, Int>>()

    override fun canNotify(): Boolean = allowed

    override fun post(alert: ClaudeAlert) {
        posted += alert
    }

    override fun cancel(serverId: String, session: String, window: Int) {
        cancelled += Triple(serverId, session, window)
    }
}

/** Sondeo de primer plano: insignias, avisos de transiciones y supresión de la ventana a la vista. */
class ClaudeActivityMonitorTest {

    private val dev = server(id = "A", name = "dev")
    private val repository = InMemoryServerRepository(listOf(dev, server(id = "B", name = "sin-conexion")))
    private val service = FakeSSHService()
    private val backend = InMemoryAgentWatchBackend()
    private val store = ClaudeWatchStore(backend)
    private val alerts = RecordingClaudeAlerts()
    private var enabled = true
    private var live: Map<String, SSHServicing> = mapOf("A" to service)
    private val watched = mutableListOf<String>()

    private fun TestScope.monitor() = ClaudeActivityMonitor(
        servers = repository,
        live = { live[it.id] },
        store = store,
        alerts = alerts,
        notificationsEnabled = { enabled },
        io = StandardTestDispatcher(testScheduler),
        onServerWatched = { watched += it },
    )

    private fun snap(text: String) = ClaudeActivitySnapshot.fromListPanes(text)

    @Test
    fun `el primer sondeo no avisa, actualiza los hooks y guarda la lectura`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = snap("-|done|%1|1|api")
        monitor.pollOnce()

        assertTrue(alerts.posted.isEmpty())
        assertEquals(1, service.hookUpgrades)
        assertEquals(ClaudeActivity.DONE, monitor.activity.value["A"]?.activity("api"))
        assertEquals(service.claudeSnapshot, store.snapshot("A"))
        assertEquals(listOf("A"), watched)
        // Solo lee los servidores con conexión ya abierta.
        assertNull(monitor.activity.value["B"])
    }

    @Test
    fun `avisa al entrar en terminado o esperando con su ventana`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = snap("-|working|%1|1|api\n-|working|%2|2|api")
        monitor.pollOnce()
        service.claudeSnapshot = snap("-|done|%1|1|api\n-|waiting|%2|2|api")
        monitor.pollOnce()

        assertEquals(
            listOf(ClaudeAlert("A", "dev", "api", 1, ClaudeActivity.DONE), ClaudeAlert("A", "dev", "api", 2, ClaudeActivity.WAITING)),
            alerts.posted,
        )
        assertEquals(1, service.hookUpgrades)
        assertEquals(listOf("A"), watched)
    }

    @Test
    fun `no avisa de la ventana que se esta mirando y retira su aviso`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = snap("-|working|%1|1|api\n-|working|%2|2|api")
        monitor.pollOnce()
        monitor.setViewing(ViewedWindow("A", "api", 1))
        assertEquals(listOf(Triple("A", "api", 1)), alerts.cancelled)

        service.claudeSnapshot = snap("-|done|%1|1|api\n-|done|%2|2|api")
        monitor.pollOnce()
        assertEquals(listOf(2), alerts.posted.map { it.window })

        // Al dejar de verla, se vuelve a avisar.
        monitor.clearViewing(ViewedWindow("A", "api", 1))
        service.claudeSnapshot = snap("-|waiting|%1|1|api\n-|done|%2|2|api")
        monitor.pollOnce()
        assertEquals(listOf(2, 1), alerts.posted.map { it.window })
    }

    @Test
    fun `sin saber la ventana activa se calla toda la sesion`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = snap("-|working|%1|1|api")
        monitor.pollOnce()
        monitor.setViewing(ViewedWindow("A", "api", null))
        service.claudeSnapshot = snap("-|done|%1|1|api")
        monitor.pollOnce()
        assertTrue(alerts.posted.isEmpty())
    }

    @Test
    fun `con los avisos desactivados o bloqueados no publica, pero la insignia sigue`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = snap("-|working|%1|1|api")
        monitor.pollOnce()
        enabled = false
        service.claudeSnapshot = snap("-|done|%1|1|api")
        monitor.pollOnce()
        enabled = true
        alerts.allowed = false
        service.claudeSnapshot = snap("-|waiting|%1|1|api")
        monitor.pollOnce()

        assertTrue(alerts.posted.isEmpty())
        assertEquals(ClaudeActivity.WAITING, monitor.activity.value["A"]?.activity("api"))
    }

    @Test
    fun `un fallo conserva lo ultimo y una conexion nueva vuelve a empezar en silencio`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = snap("-|working|%1|1|api")
        monitor.pollOnce()
        service.claudeActivityError = java.io.IOException("roto")
        monitor.pollOnce()
        assertEquals(ClaudeActivity.WORKING, monitor.activity.value["A"]?.activity("api"))

        val fresh = FakeSSHService().apply { claudeSnapshot = snap("-|done|%1|1|api") }
        live = mapOf("A" to fresh)
        monitor.pollOnce()
        assertTrue(alerts.posted.isEmpty())
        assertEquals(1, fresh.hookUpgrades)
    }

    @Test
    fun `al volver adopta lo que vio el worker y no repite el aviso`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = snap("-|working|%1|1|api")
        monitor.pollOnce()
        // En segundo plano, el worker ya leyó (y avisó) «terminó».
        store.save("A", snap("-|done|%1|1|api"))
        monitor.adoptStoredBaselines()
        service.claudeSnapshot = snap("-|done|%1|1|api")
        monitor.pollOnce()
        assertTrue(alerts.posted.isEmpty())
    }

    @Test
    fun `tras instalar los hooks el siguiente sondeo no avisa`() = runTest {
        val monitor = monitor()
        service.claudeSnapshot = ClaudeActivitySnapshot.EMPTY
        monitor.pollOnce()
        monitor.hooksInstalled("A")
        service.claudeSnapshot = snap("-|done|%1|1|api")
        monitor.pollOnce()
        assertTrue(alerts.posted.isEmpty())
        assertEquals(2, service.hookUpgrades)
    }
}

/** Comprobación en segundo plano de Claude en tmux y el resto de piezas puras. */
class ClaudeBackgroundCheckTest {

    private val store = ClaudeWatchStore(InMemoryAgentWatchBackend())
    private val alerts = RecordingClaudeAlerts()
    private var visible = false
    private val check = ClaudeBackgroundCheck(store, alerts, isAppVisible = { visible })
    private val dev = server(id = "A", name = "dev")

    @Test
    fun `sin referencia solo toma nota y despues avisa de lo nuevo`() = runTest {
        val service = FakeSSHService().apply { claudeSnapshot = ClaudeActivitySnapshot.fromListPanes("-|working|%1|3|web") }
        assertTrue(check.check(dev, service))
        assertTrue(alerts.posted.isEmpty())
        service.claudeSnapshot = ClaudeActivitySnapshot.fromListPanes("-|done|%1|3|web")
        assertTrue(check.check(dev, service))
        assertEquals(listOf(ClaudeAlert("A", "dev", "web", 3, ClaudeActivity.DONE)), alerts.posted)
        assertEquals(service.claudeSnapshot, store.snapshot("A"))
    }

    @Test
    fun `con la app a la vista no revisa nada`() = runTest {
        store.watch("A")
        assertEquals(setOf("A"), check.watchedServers())
        visible = true
        assertTrue(check.watchedServers().isEmpty())
        assertTrue(check.hasWatched())
    }

    @Test
    fun `el almacen sobrevive a un reinicio y olvida los servidores borrados`() {
        val backend = InMemoryAgentWatchBackend()
        val first = ClaudeWatchStore(backend)
        assertTrue(first.watch("A"))
        assertFalse(first.watch("A"))
        first.save("A", ClaudeActivitySnapshot.fromListPanes("0|working|%1|1|s"))
        first.dismissHooksHint("A")

        val reopened = ClaudeWatchStore(backend)
        assertEquals(setOf("A"), reopened.watchedServers())
        assertEquals(first.snapshot("A"), reopened.snapshot("A"))
        assertTrue(reopened.snapshot("A")?.panes?.single()?.isQuiet == true)
        assertTrue(reopened.isHooksHintDismissed("A"))
        reopened.forget("A")
        assertTrue(reopened.watchedServers().isEmpty())
        assertNull(reopened.snapshot("A"))
    }

    @Test
    fun `textos del aviso como en iPhone`() {
        val done = ClaudeAlert.from(ClaudeTransition("ia/web", 2, ClaudeActivity.DONE), "A", "dev")
        assertEquals("Claude terminó", done.title)
        assertEquals("ia/web · ventana 2 · dev", done.subtitle)
        assertEquals("Terminó de responder.", done.body)
        val waiting = done.copy(activity = ClaudeActivity.WAITING)
        assertEquals("Claude espera tu respuesta", waiting.title)
        assertEquals(ClaudeAlert.WAITING_BODY, waiting.body)
    }

    @Test
    fun `el enlace del aviso solo se acepta con datos sensatos`() {
        val servers = InMemoryServerRepository(listOf(dev))
        val ok = ClaudeLink.parse(ClaudeLink.ACTION_OPEN_WINDOW, "A", "ia/web", 2, servers)
        assertEquals(ClaudeTarget("A", "ia/web", 2), ok)
        assertNull(ClaudeLink.parse("otra", "A", "ia/web", 2, servers))
        assertNull(ClaudeLink.parse(ClaudeLink.ACTION_OPEN_WINDOW, "X", "ia/web", 2, servers))
        assertNull(ClaudeLink.parse(ClaudeLink.ACTION_OPEN_WINDOW, "A", "", 2, servers))
        assertNull(ClaudeLink.parse(ClaudeLink.ACTION_OPEN_WINDOW, "A", "a\nb", 2, servers))
        assertNull(ClaudeLink.parse(ClaudeLink.ACTION_OPEN_WINDOW, "A", "ia/web", -1, servers))
        assertNull(ClaudeLink.parse(ClaudeLink.ACTION_OPEN_WINDOW, null, "ia/web", 2, servers))
    }
}
