package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.LocalNetworkGate
import com.iaportafolio.argos.data.LocalNetworkPermissionException
import com.iaportafolio.argos.data.ReadOnlyHostKeyTrustStore
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.data.UntrustedHostException
import com.iaportafolio.argos.data.credentials
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Conexiones para UNA pasada del worker (avisos de CI): reutiliza la de la app si ya está abierta
 * ([shared]) y, si no, abre una propia que [closeAll] cierra al terminar. Como [AgentNotifier], nunca
 * confía en una huella nueva ni intenta la red local sin permiso.
 */
class BackgroundServiceProvider(
    private val shared: ServiceProvider,
    private val connector: SSHConnector,
    private val secrets: SecretStore,
    hostKeys: HostKeyTrustStore,
    private val localNetwork: LocalNetworkGate,
    private val io: CoroutineDispatcher,
) : ServiceProvider {

    private val trust = ReadOnlyHostKeyTrustStore(hostKeys)
    private val mutex = Mutex()
    private var owned: Map<String, SSHServicing> = emptyMap()

    override suspend fun service(server: Server): SSHServicing {
        shared.cached(server)?.let { return it }
        return mutex.withLock {
            owned[server.id] ?: withContext(io) {
                if (localNetwork.blocks(server.host)) throw LocalNetworkPermissionException(server.host)
                if (trust.trustedFingerprint(server.endpoint) == null) throw UntrustedHostException(server.endpoint)
                connector.service(server, secrets.credentials(server), trust)
            }.also { owned = owned + (server.id to it) }
        }
    }

    override fun cached(server: Server): SSHServicing? = shared.cached(server) ?: owned[server.id]

    override suspend fun invalidate(serverId: String) {
        val removed = mutex.withLock { owned[serverId].also { owned = owned - serverId } }
        removed?.let { disconnect(serverId, it) }
    }

    /** Cierra las conexiones propias (nunca las de la app). También si la pasada se canceló. */
    suspend fun closeAll() = withContext(NonCancellable) {
        val all = mutex.withLock { owned.also { owned = emptyMap() } }
        all.forEach { (id, service) -> disconnect(id, service) }
    }

    private suspend fun disconnect(serverId: String, service: SSHServicing) {
        try {
            withContext(io) { service.disconnect() }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.warn(ArgosLog.TAG_SSH, "Error al desconectar $serverId (${error::class.java.simpleName})")
        }
    }
}

/**
 * Un solo trabajo de WorkManager para todo lo que se revisa en segundo plano (agentes y CI): se
 * programa si alguno lo necesita y se cancela cuando ninguno. [wants] se consulta en cada cambio.
 */
class BackgroundCheckSchedule(
    private val work: AgentCheckScheduler,
    private val wants: List<() -> Boolean>,
) {
    fun sync() {
        if (wants.any { it() }) work.schedule() else work.cancel()
    }

    /** Vista para quien antes pedía programar o cancelar por su cuenta: ahora siempre sincroniza. */
    val asScheduler: AgentCheckScheduler = object : AgentCheckScheduler {
        override fun schedule() = sync()

        override fun cancel() = sync()
    }
}
