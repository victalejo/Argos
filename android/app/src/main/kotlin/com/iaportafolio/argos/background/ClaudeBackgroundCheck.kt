package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.status.ClaudeActivityReading
import kotlinx.coroutines.withTimeoutOrNull

/**
 * La parte de Claude en tmux de la comprobación en segundo plano (`apply` de `AgentNotifier.swift`):
 * lee el estado del servidor, avisa de lo que ENTRÓ en «terminó» / «espera tu respuesta» respecto de
 * la última lectura guardada y guarda la nueva. Sin referencia previa solo toma nota. Con la app a la
 * vista no hace nada: de eso se encarga [ClaudeActivityMonitor] (y así no se avisa dos veces).
 */
class ClaudeBackgroundCheck(
    private val store: ClaudeWatchStore,
    private val alerts: ClaudeAlertSink,
    private val isAppVisible: () -> Boolean,
    private val timeoutMillis: Long = TIMEOUT_MILLIS,
) {
    /** Lo que toca revisar ahora: nada con la app a la vista. */
    fun watchedServers(): Set<String> = if (isAppVisible()) emptySet() else store.watchedServers()

    /** Todos los servidores donde se vio Claude (para programar el worker y limpiar los borrados). */
    fun allWatched(): Set<String> = store.watchedServers()

    fun hasWatched(): Boolean = store.watchedServers().isNotEmpty()

    /** `false` si el servidor no respondió a tiempo (la excepción de red la trata quien llama). */
    suspend fun check(server: Server, service: SSHServicing): Boolean {
        val reader = service as? ClaudeActivityReading ?: return true
        val fresh = withTimeoutOrNull(timeoutMillis) { reader.claudeActivity() } ?: return false
        // Pudo volverse visible mientras se leía: el sondeo de primer plano ya lo tiene.
        if (isAppVisible()) return true
        val previous = store.snapshot(server.id)
        if (previous != null && alerts.canNotify()) {
            fresh.notableTransitions(previous).forEach { alerts.post(ClaudeAlert.from(it, server.id, server.name)) }
        }
        store.save(server.id, fresh)
        return true
    }

    fun serverDeleted(serverId: String) = store.forget(serverId)

    private companion object {
        const val TIMEOUT_MILLIS = 30_000L
    }
}
