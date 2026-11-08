package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Faltan los datos de acceso de un servidor (p. ej. tras restaurar el teléfono). */
class MissingCredentialsException(message: String) : Exception(message)

/** Entrega el [SSHServicing] de un servidor. Abstracción para los ViewModels y sus tests. */
interface ServiceProvider {
    /** Servicio (conexión perezosa) del servidor; se reutiliza mientras el servidor no cambie. */
    suspend fun service(server: Server): SSHServicing

    /** Cierra y descarta el servicio cacheado (servidor editado, borrado o huella olvidada). */
    suspend fun invalidate(serverId: String)
}

/**
 * Una conexión por servidor, compartida por todas las pantallas (equivale a `ServerHub` de
 * Apple). Lee los secretos del [SecretStore] justo antes de crear el servicio y lo descarta si
 * la configuración del servidor cambió desde entonces.
 */
class ServiceHub(
    private val connector: SSHConnector,
    private val secrets: SecretStore,
    private val trust: HostKeyTrustStore,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ServiceProvider {

    private data class Entry(val server: Server, val service: SSHServicing)

    private val mutex = Mutex()
    private var entries: Map<String, Entry> = emptyMap()

    override suspend fun service(server: Server): SSHServicing {
        val (fresh, stale) = mutex.withLock {
            val cached = entries[server.id]
            if (cached != null && cached.server == server) return cached.service
            val credentials = withContext(io) { credentials(server) }
            val entry = Entry(server, connector.service(server, credentials, trust))
            entries = entries + (server.id to entry)
            entry to cached
        }
        stale?.let { disconnectQuietly(it) }
        return fresh.service
    }

    override suspend fun invalidate(serverId: String) {
        val removed = mutex.withLock {
            entries[serverId].also { entries = entries - serverId }
        }
        removed?.let { disconnectQuietly(it) }
    }

    private suspend fun disconnectQuietly(entry: Entry) {
        try {
            withContext(io) { entry.service.disconnect() }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.warn(ArgosLog.TAG_SSH, "Error al desconectar ${entry.server.endpoint}", error)
        }
    }

    private fun credentials(server: Server): SSHCredentials = when (server.authMethod) {
        AuthMethod.PASSWORD -> SSHCredentials.Password(
            secrets.read(server.id, SecretKind.PASSWORD)
                ?: throw MissingCredentialsException(
                    "No hay contraseña guardada para «${server.name}». Edita el servidor y escríbela.",
                ),
        )
        AuthMethod.KEY -> SSHCredentials.PrivateKey(
            openSSHPem = secrets.read(server.id, SecretKind.PRIVATE_KEY)
                ?: throw MissingCredentialsException(
                    "No hay clave privada importada para «${server.name}». Edita el servidor e impórtala.",
                ),
            passphrase = if (server.requiresPassphrase) {
                secrets.read(server.id, SecretKind.PASSPHRASE)
                    ?: throw MissingCredentialsException(
                        "Falta la passphrase de la clave de «${server.name}». Edita el servidor y escríbela.",
                    )
            } else {
                null
            },
        )
    }
}
