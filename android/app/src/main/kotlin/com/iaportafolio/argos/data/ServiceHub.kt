package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.ssh.SshConnectionException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.IOException

/** Faltan los datos de acceso de un servidor (p. ej. tras restaurar el teléfono). */
class MissingCredentialsException(message: String) : Exception(message)

/** Entrega el [SSHServicing] de un servidor. Abstracción para los ViewModels y sus tests. */
interface ServiceProvider {
    /** Servicio (conexión perezosa) del servidor; se reutiliza mientras el servidor no cambie. */
    suspend fun service(server: Server): SSHServicing

    /** Cierra y descarta el servicio cacheado (servidor editado, borrado o huella olvidada). */
    suspend fun invalidate(serverId: String)

    /** El servicio YA abierto de [server], sin crear ninguno (`null` si no hay o cambió). */
    fun cached(server: Server): SSHServicing? = null
}

/**
 * Una conexión por servidor, compartida por todas las pantallas (equivale a `ServerHub` de
 * Apple). Lee los secretos del [SecretStore] justo antes de crear el servicio y lo descarta si
 * la configuración del servidor cambió desde entonces.
 *
 * Con [localNetwork], un servidor de la red local sin el permiso de Android 17 falla al momento
 * con [LocalNetworkPermissionException] en vez de esperar un «timeout». [onDisconnected] se llama
 * cada vez que se cierra un servicio (sus túneles de puertos mueren con él).
 */
class ServiceHub(
    private val connector: SSHConnector,
    private val secrets: SecretStore,
    private val trust: HostKeyTrustStore,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val localNetwork: LocalNetworkGate = LocalNetworkGate.NotRequired,
    private val onDisconnected: (serverId: String) -> Unit = {},
) : ServiceProvider {

    private data class Entry(val server: Server, val service: SSHServicing)

    private val mutex = Mutex()

    /** Se sustituye entero (inmutable): [cached] lo lee sin el mutex. */
    @Volatile
    private var entries: Map<String, Entry> = emptyMap()

    override suspend fun service(server: Server): SSHServicing {
        val (fresh, stale) = mutex.withLock {
            val cached = entries[server.id]
            if (cached != null && cached.server == server) return cached.service
            if (withContext(io) { localNetwork.blocks(server.host) }) throw LocalNetworkPermissionException(server.host)
            val credentials = withContext(io) { secrets.credentials(server) }
            val entry = Entry(server, connector.service(server, credentials, trust))
            entries = entries + (server.id to entry)
            entry to cached
        }
        stale?.let { disconnectQuietly(it) }
        return fresh.service
    }

    override fun cached(server: Server): SSHServicing? = entries[server.id]?.takeIf { it.server == server }?.service

    override suspend fun invalidate(serverId: String) {
        val removed = mutex.withLock {
            entries[serverId].also { entries = entries - serverId }
        }
        removed?.let { disconnectQuietly(it) }
    }

    /** Cierra todas las conexiones (app en segundo plano sin nada que mantener, o red nueva). */
    suspend fun closeAll() {
        val removed = mutex.withLock { entries.values.toList().also { entries = emptyMap() } }
        removed.forEach { disconnectQuietly(it) }
    }

    /** Servidores con una conexión abierta. */
    fun connectedServerIds(): Set<String> = entries.keys

    /**
     * Comprueba con un plazo corto que cada conexión abierta responde y cierra las que no (NAT
     * caducado, Doze): así la pantalla siguiente reconecta en vez de esperar 30–90 s. Devuelve
     * los servidores descartados.
     */
    suspend fun probeAll(timeoutMillis: Long): Set<String> {
        val dead = entries.values.filterNot { isResponsive(it, timeoutMillis) }
        dead.forEach { entry ->
            // Solo si sigue siendo la misma conexión (otra pantalla pudo renovarla entretanto).
            val removed = mutex.withLock {
                entries[entry.server.id]?.takeIf { it.service === entry.service }?.also { entries = entries - entry.server.id }
            }
            removed?.let { disconnectQuietly(it) }
        }
        return dead.map { it.server.id }.toSet()
    }

    private suspend fun isResponsive(entry: Entry, timeoutMillis: Long): Boolean = try {
        // TODO(integración): usar la sonda específica que está añadiendo el módulo `ssh` (más barata
        //  que `tmux ls`) en cuanto exista en `SSHServicing`.
        withTimeout(timeoutMillis) { withContext(io) { entry.service.listSessions() } }
        true
    } catch (timeout: TimeoutCancellationException) {
        ArgosLog.warn(ArgosLog.TAG_SSH, "La conexión con ${entry.server.endpoint} no respondió en $timeoutMillis ms")
        false
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (error: IOException) {
        ArgosLog.warn(ArgosLog.TAG_SSH, "La conexión con ${entry.server.endpoint} está caída", error)
        false
    } catch (error: SshConnectionException) {
        ArgosLog.warn(ArgosLog.TAG_SSH, "La conexión con ${entry.server.endpoint} está caída", error)
        false
    } catch (error: Exception) {
        // Responde aunque sea con un error (p. ej. sin tmux): la conexión vale.
        true
    }

    private suspend fun disconnectQuietly(entry: Entry) {
        try {
            withContext(io) { entry.service.disconnect() }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.warn(ArgosLog.TAG_SSH, "Error al desconectar ${entry.server.endpoint}", error)
        } finally {
            onDisconnected(entry.server.id)
        }
    }
}
