package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.status.ClaudeActivityReading
import com.iaportafolio.argos.core.status.ClaudeActivitySnapshot
import com.iaportafolio.argos.core.status.ClaudeHookMaintenance
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Qué sabe una pantalla del estado de Claude de un servidor. Abstracción para los ViewModels y sus tests. */
interface ClaudeActivitySource {
    /** Última lectura por servidor (sin entrada = aún no se leyó). */
    val activity: StateFlow<Map<String, ClaudeActivitySnapshot>>

    /** Ventana en pantalla: de ella no se avisa y se retira su aviso. */
    fun setViewing(window: ViewedWindow)

    /** [window] dejó de verse (si otra ocupó su lugar entretanto, no cambia nada). */
    fun clearViewing(window: ViewedWindow)

    /** Se acaban de instalar los hooks: el servidor se vuelve a leer en el próximo sondeo como si fuera el primero. */
    fun hooksInstalled(serverId: String) = Unit

    /** Sin indicador (tests de pantallas que no lo usan). */
    object None : ClaudeActivitySource {
        override val activity: StateFlow<Map<String, ClaudeActivitySnapshot>> = MutableStateFlow(emptyMap<String, ClaudeActivitySnapshot>()).asStateFlow()
        override fun setViewing(window: ViewedWindow) = Unit
        override fun clearViewing(window: ViewedWindow) = Unit
    }
}

/**
 * Estado de Claude Code en las ventanas tmux con la app a la vista (port del sondeo de
 * `ServerHub.startActivityPolling` + `SessionsViewModel.refreshClaudeActivity` de iOS): cada
 * [intervalMillis] lee, con un solo comando, el estado de los servidores que YA tienen conexión abierta
 * en el `ServiceHub` ([live]): nunca abre conexiones nuevas. Alimenta las insignias de la lista y de
 * las pestañas y avisa de «terminó» / «espera tu respuesta», salvo de la ventana que se está mirando.
 *
 * - El primer sondeo de cada servidor en este proceso no avisa (no se sabe qué es nuevo) y actualiza
 *   los hooks si son de una versión anterior (como el Mac).
 * - Cada lectura se guarda en [store]: es la referencia del worker en segundo plano, y al volver a
 *   primer plano se adopta lo que el worker haya visto ([adoptStoredBaselines]) para no repetir avisos.
 * - Un servidor que falla o no responde conserva lo último y no retrasa a los demás.
 */
class ClaudeActivityMonitor(
    private val servers: ServerRepository,
    private val live: (Server) -> SSHServicing?,
    private val store: ClaudeWatchStore,
    private val alerts: ClaudeAlertSink,
    private val notificationsEnabled: () -> Boolean,
    private val io: CoroutineDispatcher,
    /** Se vio Claude por primera vez en un servidor: programar el worker y pedir permiso de avisos. */
    private val onServerWatched: (serverId: String) -> Unit = {},
    private val intervalMillis: Long = POLL_INTERVAL_MILLIS,
    private val serverTimeoutMillis: Long = SERVER_TIMEOUT_MILLIS,
) : ClaudeActivitySource {

    private val mutableActivity = MutableStateFlow<Map<String, ClaudeActivitySnapshot>>(emptyMap())
    override val activity: StateFlow<Map<String, ClaudeActivitySnapshot>> = mutableActivity.asStateFlow()

    /** Servicio con el que se hizo el primer sondeo de cada servidor (otro = conexión nueva). */
    private val polledWith = mutableMapOf<String, SSHServicing>()

    /** Servidores cuyo próximo sondeo no avisa (primera lectura o hooks recién instalados). */
    private val silentNext = mutableSetOf<String>()

    @Volatile
    private var viewing: ViewedWindow? = null

    override fun setViewing(window: ViewedWindow) {
        viewing = window
        val shown = window.window ?: return
        alerts.cancel(window.serverId, window.session, shown)
    }

    override fun clearViewing(window: ViewedWindow) {
        if (viewing == window) viewing = null
    }

    override fun hooksInstalled(serverId: String) {
        synchronized(polledWith) { silentNext += serverId }
    }

    /** Sondea hasta que se cancele (la app deja de verse). */
    suspend fun runWhileVisible() {
        adoptStoredBaselines()
        while (true) {
            pollOnce()
            delay(intervalMillis)
        }
    }

    /**
     * Al volver a primer plano: lo que el worker ya avisó en segundo plano pasa a ser lo último
     * conocido (solo para los servidores ya sondeados; el primero nunca avisa).
     */
    fun adoptStoredBaselines() {
        val known = mutableActivity.value
        val adopted = known.mapValues { (serverId, current) -> store.snapshot(serverId) ?: current }
        if (adopted != known) mutableActivity.value = adopted
    }

    /** Una pasada por los servidores con conexión abierta, en paralelo. */
    suspend fun pollOnce() = coroutineScope {
        servers.servers.value.mapNotNull { server ->
            val service = live(server) ?: return@mapNotNull null
            val reader = service as? ClaudeActivityReading ?: return@mapNotNull null
            async { poll(server, service, reader) }
        }.awaitAll()
        Unit
    }

    private suspend fun poll(server: Server, service: SSHServicing, reader: ClaudeActivityReading) {
        val fresh = read(server, reader) ?: return
        val first = synchronized(polledWith) {
            val isNew = polledWith[server.id] !== service
            polledWith[server.id] = service
            val silent = isNew || server.id in silentNext
            silentNext -= server.id
            silent
        }
        if (first) upgradeHooks(server, service)
        val previous = mutableActivity.value[server.id]
        mutableActivity.update { it + (server.id to fresh) }
        store.save(server.id, fresh)
        if (fresh.panes.isNotEmpty() && store.watch(server.id)) onServerWatched(server.id)
        if (first || previous == null || previous == fresh) return
        notify(server, fresh, previous)
    }

    private suspend fun read(server: Server, reader: ClaudeActivityReading): ClaudeActivitySnapshot? = try {
        withTimeoutOrNull(serverTimeoutMillis) { withContext(io) { reader.claudeActivity() } }
            .also { if (it == null) ArgosLog.warn(ArgosLog.TAG_SSH, "El estado de Claude de ${server.endpoint} no llegó a tiempo") }
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (error: Exception) {
        // Fallo de red o canal rechazado: se conserva lo último (como el `try?` de iOS).
        ArgosLog.warn(ArgosLog.TAG_SSH, "No se pudo leer el estado de Claude de ${server.endpoint}: ${error.userMessage}")
        null
    }

    private fun notify(server: Server, fresh: ClaudeActivitySnapshot, previous: ClaudeActivitySnapshot) {
        if (!notificationsEnabled() || !alerts.canNotify()) return
        val shown = viewing
        fresh.notableTransitions(previous)
            .filterNot { shown?.covers(server.id, it) == true }
            .forEach { alerts.post(ClaudeAlert.from(it, server.id, server.name)) }
    }

    /** Una vez por conexión: si el indicador se activó con hooks antiguos, se ponen al día. */
    private suspend fun upgradeHooks(server: Server, service: SSHServicing) {
        val maintenance = service as? ClaudeHookMaintenance ?: return
        try {
            if (withContext(io) { maintenance.upgradeClaudeHooksIfOutdated() }) {
                ArgosLog.info(ArgosLog.TAG_SSH, "Hooks de Claude actualizados en ${server.endpoint}")
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.warn(ArgosLog.TAG_SSH, "No se pudieron actualizar los hooks de Claude en ${server.endpoint}: ${error.userMessage}")
        }
    }

    /** Servidor borrado: se olvida su estado. */
    fun serverDeleted(serverId: String) {
        mutableActivity.update { it - serverId }
        synchronized(polledWith) {
            polledWith -= serverId
            silentNext -= serverId
        }
        store.forget(serverId)
    }

    companion object {
        /** Como iOS: cada 5 s con la app delante. */
        const val POLL_INTERVAL_MILLIS = 5_000L

        /** Un servidor colgado no retrasa la insignia de los demás. */
        const val SERVER_TIMEOUT_MILLIS = 10_000L
    }
}
