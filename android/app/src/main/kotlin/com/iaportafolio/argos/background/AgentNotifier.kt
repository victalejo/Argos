package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.agent.AgentAttentionPlanner
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ClaudeTokenStore
import com.iaportafolio.argos.data.ReadOnlyHostKeyTrustStore
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.credentials
import com.iaportafolio.argos.ui.agents.SecretRedactor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Instant

/** Qué pasó en una comprobación. */
enum class AgentCheckOutcome {
    /** Se revisaron los servidores apuntados (los que fallan no cambian el resultado). */
    CHECKED,

    /** Avisos desactivados en Argos. */
    DISABLED,

    /** El sistema bloquea las notificaciones: no se abre ninguna conexión para nada. */
    BLOCKED,

    /** Ya había otra comprobación en marcha. */
    BUSY,
}

/**
 * Avisos de los agentes: «terminó» y «espera tu permiso» (port de `AgentNotifier.swift`). Sin
 * servidores intermedios ni push: se lee el final del log de los agentes y se avisa de lo nuevo.
 *
 * Cada servidor abre una conexión NUEVA (no la de `ServiceHub`) que siempre se cierra. Nunca confía
 * en una huella nueva: un endpoint sin huella guardada se salta hasta que el usuario conecte desde
 * la app. Un servidor que falla no afecta a los demás y se registra sin secretos ni contenido.
 */
class AgentNotifier(
    private val servers: ServerRepository,
    private val secrets: SecretStore,
    hostKeys: HostKeyTrustStore,
    private val connector: SSHConnector,
    private val tokens: ClaudeTokenStore,
    private val store: AgentWatchStore,
    private val alerts: AgentAlertSink,
    private val scheduler: AgentCheckScheduler,
    private val io: CoroutineDispatcher,
    private val serverTimeoutMillis: Long = SERVER_TIMEOUT_MILLIS,
    private val clock: () -> Instant = Instant::now,
    private val log: (String) -> Unit = { ArgosLog.warn(ArgosLog.TAG_AGENT, it) },
) : AgentAttentionTracker {

    private val trust = ReadOnlyHostKeyTrustStore(hostKeys)
    private val checking = Mutex()
    private val shownChats = mutableSetOf<Pair<String, String>>()

    override val notificationsEnabled: StateFlow<Boolean> = store.notificationsEnabled

    /** Revisa los servidores apuntados. Si ya hay otra comprobación, no se solapa. */
    suspend fun check(): AgentCheckOutcome {
        if (!checking.tryLock()) return AgentCheckOutcome.BUSY
        return try {
            runCheck()
        } finally {
            checking.unlock()
        }
    }

    private suspend fun runCheck(): AgentCheckOutcome {
        if (!store.notificationsEnabled.value) return AgentCheckOutcome.DISABLED
        if (!alerts.canNotify()) return AgentCheckOutcome.BLOCKED
        val configured = servers.servers.value
        val watched = store.watchedServers()
        // Se limpia aquí también por si se borró un servidor con la app a medias.
        (watched - configured.map { it.id }.toSet()).forEach(::serverDeleted)
        val targets = configured.filter { it.id in watched }
        if (targets.isEmpty()) return AgentCheckOutcome.CHECKED
        val redactor = SecretRedactor(readToken())
        targets.forEach { checkServer(it, redactor) }
        return AgentCheckOutcome.CHECKED
    }

    /** Sin el token no se puede tapar el exacto, pero sigue tapándose lo que tenga su forma. */
    private suspend fun readToken(): String? = try {
        withContext(io) { tokens.read() }
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (error: Exception) {
        log("No se pudo leer el token para los avisos (${error::class.java.simpleName})")
        null
    }

    private suspend fun checkServer(server: Server, redactor: SecretRedactor) {
        try {
            withContext(io) {
                if (trust.trustedFingerprint(server.endpoint) == null) {
                    log("Servidor ${server.id} sin huella guardada: no se revisa en segundo plano")
                } else {
                    val service = connector.service(server, secrets.credentials(server), trust)
                    try {
                        readAndNotify(server, service, redactor)
                    } finally {
                        disconnect(server, service)
                    }
                }
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            log("No se pudo revisar el servidor ${server.id} (${error::class.java.simpleName})")
        }
    }

    private suspend fun readAndNotify(server: Server, service: SSHServicing, redactor: SecretRedactor) {
        val output = withTimeoutOrNull(serverTimeoutMillis) { service.runAgentScript(PersistentAgentScript.snapshots()) }
        if (output == null) {
            log("El servidor ${server.id} no respondió a tiempo")
            return
        }
        val before = store.seenBytes(server.id)
        val plan = AgentAttentionPlanner.notices(PersistentAgentScript.parseSnapshots(output), before, clock())
        plan.notices.filterNot { isShown(server.id, it.agentID) }.forEach { notice ->
            alerts.post(
                AgentAlert(
                    serverId = server.id,
                    serverName = server.name,
                    agentId = notice.agentID,
                    title = redactor.redact(notice.title),
                    body = redactor.redact(notice.body),
                ),
            )
        }
        store.applyCheck(server.id, before, plan.seen)
    }

    /** También si la comprobación se canceló: un socket abierto en segundo plano gasta batería. */
    private suspend fun disconnect(server: Server, service: SSHServicing) = withContext(NonCancellable) {
        try {
            service.disconnect()
        } catch (error: Exception) {
            log("Error al desconectar el servidor ${server.id} (${error::class.java.simpleName})")
        }
    }

    // MARK: - Lo que cuentan las pantallas

    override fun setNotificationsEnabled(enabled: Boolean) {
        store.setNotificationsEnabled(enabled)
        syncSchedule()
    }

    override fun agentOpened(serverId: String) {
        store.watch(serverId)
        syncSchedule()
    }

    override fun chatShown(serverId: String, agentId: String) {
        synchronized(shownChats) { shownChats += serverId to agentId }
        alerts.cancel(serverId, agentId)
    }

    override fun chatHidden(serverId: String, agentId: String, receivedBytes: Long) {
        store.markSeen(serverId, agentId, receivedBytes)
        synchronized(shownChats) { shownChats -= serverId to agentId }
    }

    override fun serverDeleted(serverId: String) {
        store.unwatch(serverId).forEach { alerts.cancel(serverId, it) }
        syncSchedule()
    }

    /** ¿Se debe pedir el permiso de notificaciones ahora? Una sola vez y con los avisos activados. */
    fun claimPermissionRequest(alreadyGranted: Boolean): Boolean =
        !alreadyGranted && store.notificationsEnabled.value && store.claimPermissionRequest()

    private fun isShown(serverId: String, agentId: String): Boolean =
        synchronized(shownChats) { (serverId to agentId) in shownChats }

    private fun syncSchedule() {
        if (store.notificationsEnabled.value && store.watchedServers().isNotEmpty()) scheduler.schedule() else scheduler.cancel()
    }

    private companion object {
        /** Holgado: conectar (15 s) + el script. Un servidor colgado no bloquea a los demás. */
        const val SERVER_TIMEOUT_MILLIS = 45_000L
    }
}

/** Ejecuta [action] cada [intervalMillis], empezando tras la primera espera, hasta que se cancele. */
suspend fun runEvery(intervalMillis: Long, action: suspend () -> Unit) {
    while (true) {
        delay(intervalMillis)
        action()
    }
}
