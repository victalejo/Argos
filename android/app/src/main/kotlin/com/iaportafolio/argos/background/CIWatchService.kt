package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.github.CIResult
import com.iaportafolio.argos.core.github.CIWatcher
import com.iaportafolio.argos.core.github.GitHubOperations
import com.iaportafolio.argos.core.github.GitHubStatusResult
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant

/** Dónde se avisa de un CI terminado (notificación del sistema; un doble en los tests). */
fun interface CIAlertSink {
    fun post(serverId: String, serverName: String, result: CIResult)
}

/**
 * Avisos «el CI de app pasó/falló» (port de `SessionsViewModel+CI` de Apple): vigila los commits
 * que el usuario subió desde «Cambios» o vio con el CI en curso, aunque cierre la pantalla. Un
 * solo bucle para todos los servidores, vivo solo mientras haya algo que vigilar; la lógica de
 * cuándo dejarlo está en [CIWatcher] (core).
 *
 * Lo vigilado se guarda en [store]: si el proceso muere, el worker de WorkManager lo sigue
 * revisando ([pollWith]). El bucle de aquí solo consulta con la app a la vista ([isVisible]); en
 * segundo plano lo hace el worker. [onWatchesChanged] reprograma ese worker.
 */
class CIWatchService(
    private val servers: ServerRepository,
    private val services: ServiceProvider,
    private val alerts: CIAlertSink,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val clock: () -> Instant = Instant::now,
    private val store: CIWatchStore? = null,
    private val isVisible: () -> Boolean = { true },
    private val onWatchesChanged: () -> Unit = {},
) {
    /** Vigilante por servidor. Solo se toca en el hilo de [scope] (Main). */
    private val watchers: MutableMap<String, CIWatcher> =
        store?.load().orEmpty().mapValues { (_, watches) -> CIWatcher(watches) }.toMutableMap()
    private var loop: Job? = null
    private val mutableCount = MutableStateFlow(watchCount())

    val isWatching: Boolean get() = watchers.values.any { !it.isEmpty }

    /** Commits vigilados ahora (diagnóstico). */
    val watchCountFlow: StateFlow<Int> = mutableCount.asStateFlow()

    /** Empieza a vigilar el CI de [root] (`sha` nulo tras un push: el HEAD subido). */
    fun watch(serverId: String, root: String, name: String, sha: String?) {
        val current = watchers[serverId] ?: CIWatcher()
        watchers[serverId] = current.watch(root, name, sha, clock())
        persist()
        resume()
    }

    /** Arranca el bucle si hay algo que vigilar (al crear y al volver a primer plano). */
    fun resume() {
        if (isWatching && loop?.isActive != true) loop = scope.launch { run() }
    }

    private suspend fun run() {
        while (isWatching) {
            if (isVisible()) pollOnce()
            if (!isWatching) break
            delay(CIWatcher.POLL_INTERVAL.toMillis())
        }
    }

    /** Una pasada del worker con sus propias conexiones. Llamar desde el hilo principal. */
    suspend fun pollWith(provider: ServiceProvider) = pollOnce(provider)

    /** Una vuelta: lee cada commit vigilado que toque y avisa de los que terminaron. */
    internal suspend fun pollOnce(provider: ServiceProvider = services) {
        for (serverId in watchers.keys.toList()) {
            val now = clock()
            var watcher = watchers[serverId] ?: continue
            if (!watcher.isDue(now)) continue
            watcher = watcher.polled(now)
            val server = servers.server(serverId)
            if (server == null) {
                watchers.remove(serverId)
                continue
            }
            for (root in watcher.watches.keys.sorted()) {
                val result = read(provider, serverId, root) ?: continue
                val (next, done) = watcher.apply(result, root, now)
                watcher = next
                done?.let { alerts.post(serverId, server.name, it) }
            }
            watchers[serverId] = watcher
        }
        watchers.entries.removeAll { it.value.isEmpty }
        persist()
    }

    private fun persist() {
        store?.save(watchers.mapValues { it.value.watches })
        mutableCount.value = watchCount()
        onWatchesChanged()
    }

    private fun watchCount(): Int = watchers.values.sumOf { it.watches.size }

    private suspend fun read(provider: ServiceProvider, serverId: String, root: String): GitHubStatusResult? = try {
        val server = servers.server(serverId) ?: return null
        val gitHub = provider.service(server) as? GitHubOperations ?: return GitHubStatusResult.GhMissing
        withContext(io) { gitHub.gitHubStatus(root) }
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (error: Exception) {
        ArgosLog.warn(ArgosLog.TAG_SSH, "CI vigilado de $root: ${error::class.java.simpleName}")
        null
    }
}
