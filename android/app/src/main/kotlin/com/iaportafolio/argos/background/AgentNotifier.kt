package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.ConnectionPriority
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.agent.AgentAttentionPlanner
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ClaudeTokenStore
import com.iaportafolio.argos.data.LocalNetworkGate
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
 * Si la app ya tiene abierta la conexión del servidor ([live], la del `ServiceHub`), la reutiliza y
 * no la cierra; si no, abre una NUEVA que siempre se cierra. Nunca confía en una huella nueva: un
 * endpoint sin huella guardada se salta hasta que el usuario conecte desde la app. Un servidor de la
 * red local sin el permiso de Android 17 ([localNetwork]) se salta sin contarlo como caído. Un
 * servidor que falla no afecta a los demás y se registra sin secretos ni contenido. Cada
 * comprobación queda en [diagnostics] para la pantalla de diagnóstico.
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
    /** Conexión ya abierta por la app (no se cierra al terminar). */
    private val live: (Server) -> SSHServicing? = { null },
    private val localNetwork: LocalNetworkGate = LocalNetworkGate.NotRequired,
    private val diagnostics: BackgroundDiagnosticsStore? = null,
    /** Claude Code en las ventanas tmux de los servidores donde se vio (solo en segundo plano). */
    private val claude: ClaudeBackgroundCheck? = null,
) : AgentAttentionTracker {

    private val trust = ReadOnlyHostKeyTrustStore(hostKeys)
    private val checking = Mutex()
    private val shownChats = mutableSetOf<Pair<String, String>>()

    override val notificationsEnabled: StateFlow<Boolean> = store.notificationsEnabled

    /**
     * Revisa los servidores apuntados. Si ya hay otra comprobación, no se solapa. Con [liveOnly]
     * solo los que ya tienen una conexión abierta en la app (el sondeo de cada minuto a la vista: no
     * abre conexiones nuevas); sin nada que revisar no se registra en el diagnóstico.
     */
    suspend fun check(trigger: CheckTrigger = CheckTrigger.BACKGROUND, liveOnly: Boolean = false): AgentCheckOutcome {
        if (!checking.tryLock()) return AgentCheckOutcome.BUSY
        return try {
            // Lo que no pidió el usuario es fondo: no insiste contra un servidor caído ni con
            // credenciales rechazadas (ver `ConnectionHealth`).
            val (outcome, results) = if (trigger == CheckTrigger.MANUAL) {
                runCheck(liveOnly, trigger)
            } else {
                ConnectionPriority.background { runCheck(liveOnly, trigger) }
            }
            if (!(liveOnly && results.isEmpty())) {
                diagnostics?.record(CheckRecord(clock(), trigger, outcome, results.groupingBy { it }.eachCount()))
            }
            outcome
        } finally {
            checking.unlock()
        }
    }

    /** ¿Hay algo que revisar? (avisos activados y algún servidor apuntado, por agentes o por Claude en tmux). */
    fun hasWatchedServers(): Boolean =
        store.notificationsEnabled.value && (store.watchedServers().isNotEmpty() || claude?.hasWatched() == true)

    private suspend fun runCheck(liveOnly: Boolean, trigger: CheckTrigger): Pair<AgentCheckOutcome, List<ServerCheckResult>> {
        if (!store.notificationsEnabled.value) return AgentCheckOutcome.DISABLED to emptyList()
        if (!alerts.canNotify()) return AgentCheckOutcome.BLOCKED to emptyList()
        val configured = servers.servers.value
        val watched = store.watchedServers()
        // Se limpia aquí también por si se borró un servidor con la app a medias.
        val existing = configured.map { it.id }.toSet()
        (watched - existing).forEach(::serverDeleted)
        claude?.let { check -> (check.allWatched() - existing).forEach(check::serverDeleted) }
        // Con la app a la vista, Claude en tmux lo sondea `ClaudeActivityMonitor` (sin abrir conexiones).
        val claudeIds = if (trigger == CheckTrigger.FOREGROUND) emptySet() else claude?.watchedServers().orEmpty()
        val targets = configured.filter { (it.id in watched || it.id in claudeIds) && (!liveOnly || live(it) != null) }
        if (targets.isEmpty()) return AgentCheckOutcome.CHECKED to emptyList()
        val redactor = SecretRedactor(readToken())
        val results = targets.map { checkServer(it, redactor, ServerChecks(agents = it.id in watched, claude = it.id in claudeIds)) }
        // Si ya no queda ninguno que revisar, se cancela el trabajo periódico. Al final: hacerlo
        // a mitad cortaría los servidores que faltan.
        if (!hasWatchedServers()) scheduler.cancel()
        return AgentCheckOutcome.CHECKED to results
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

    /** Qué se revisa en un servidor. */
    private data class ServerChecks(val agents: Boolean, val claude: Boolean)

    private suspend fun checkServer(server: Server, redactor: SecretRedactor, checks: ServerChecks): ServerCheckResult = try {
        withContext(io) {
            val shared = live(server)
            when {
                shared != null -> readAndNotify(server, shared, redactor, checks)
                localNetwork.blocks(server.host) -> {
                    log("Servidor ${server.id} en la red local sin permiso: no se revisa")
                    ServerCheckResult.LOCAL_NETWORK_BLOCKED
                }
                trust.trustedFingerprint(server.endpoint) == null -> {
                    log("Servidor ${server.id} sin huella guardada: no se revisa en segundo plano")
                    ServerCheckResult.UNTRUSTED
                }
                else -> {
                    val service = connector.service(server, secrets.credentials(server), trust)
                    try {
                        readAndNotify(server, service, redactor, checks)
                    } finally {
                        disconnect(server, service)
                    }
                }
            }
        }
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (error: Exception) {
        log("No se pudo revisar el servidor ${server.id} (${error::class.java.simpleName})")
        ServerCheckResult.FAILED
    }

    private suspend fun readAndNotify(server: Server, service: SSHServicing, redactor: SecretRedactor, checks: ServerChecks): ServerCheckResult {
        val agents = if (checks.agents) readAgentsAndNotify(server, service, redactor) else ServerCheckResult.CHECKED
        if (checks.claude && claude?.check(server, service) == false) {
            log("El servidor ${server.id} no respondió a tiempo (Claude en tmux)")
            return ServerCheckResult.NO_RESPONSE
        }
        return agents
    }

    private suspend fun readAgentsAndNotify(server: Server, service: SSHServicing, redactor: SecretRedactor): ServerCheckResult {
        val mark = store.watchMark()
        val output = withTimeoutOrNull(serverTimeoutMillis) { service.runAgentScript(PersistentAgentScript.snapshots()) }
        if (output == null) {
            log("El servidor ${server.id} no respondió a tiempo")
            return ServerCheckResult.NO_RESPONSE
        }
        val before = store.seenBytes(server.id)
        val snapshots = PersistentAgentScript.parseSnapshots(output)
        val plan = AgentAttentionPlanner.notices(snapshots, before, clock())
        val folders = snapshots.associate { it.id to it.workingDirectory }
        plan.notices.filterNot { isShown(server.id, it.agentID) }.forEach { notice ->
            alerts.post(
                AgentAlert(
                    serverId = server.id,
                    serverName = server.name,
                    agentId = notice.agentID,
                    title = redactor.redact(notice.title),
                    body = redactor.redact(notice.body),
                    projectPath = folders[notice.agentID]?.takeIf { it.isNotEmpty() },
                ),
            )
        }
        store.applyCheck(server.id, before, plan.seen)
        // Sin ningún agente en marcha ya no puede haber nada nuevo que avisar: se deja de abrir
        // una conexión SSH periódica a este servidor hasta que se arranque o reanude un agente.
        // Solo si la salida se entendió ENTERA: una línea ilegible o truncada podría ser un agente
        // vivo, y pausar lo dejaría sin avisos.
        val listed = output.lineSequence().count { it.isNotBlank() }
        if (listed == snapshots.size && snapshots.none { it.isAlive }) store.pause(server.id, mark)
        return ServerCheckResult.CHECKED
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
        claude?.serverDeleted(serverId)
        syncSchedule()
    }

    /**
     * ¿Se debe pedir el permiso de notificaciones ahora? Una sola vez. Para los avisos de agentes
     * solo si están activados; el terminal ([forTerminal]) lo necesita igualmente para su
     * notificación fija («Desconectar todo») y para los avisos de CI.
     */
    fun claimPermissionRequest(alreadyGranted: Boolean, forTerminal: Boolean = false): Boolean =
        !alreadyGranted && (forTerminal || store.notificationsEnabled.value) && store.claimPermissionRequest()

    private fun isShown(serverId: String, agentId: String): Boolean =
        synchronized(shownChats) { (serverId to agentId) in shownChats }

    private fun syncSchedule() {
        if (hasWatchedServers()) scheduler.schedule() else scheduler.cancel()
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
