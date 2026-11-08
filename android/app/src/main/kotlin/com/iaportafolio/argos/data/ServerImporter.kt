package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.keys.ServerTransfer

/** Endpoint `host:puerto` del servidor del QR: la identidad TOFU, como [Server.endpoint]. */
val ServerTransfer.endpoint: String get() = "$host:$port"

/**
 * Da de alta el servidor de un QR del Mac (equivale a `ServerHub.importTransfer` de iOS).
 *
 * - Crea un [Server] con [AuthMethod.KEY] y sin passphrase.
 * - Guarda `privateKeyPem()` CIFRADA en el [SecretStore] (nunca en claro ni en logs).
 * - Si el QR trae huella y el endpoint no tiene ninguna, la confía; si ya había otra distinta,
 *   aborta con [ServerTransfer.HostKeyConflictException] (se comprueba antes de escribir nada y
 *   otra vez justo al guardar la huella).
 * - Todo o nada: si falla cualquier paso, se deshace lo escrito (clave y huella nueva).
 *
 * Bloqueante (disco y criptografía): llamar fuera del hilo principal.
 */
class ServerImporter(
    private val repository: ServerRepository,
    private val secrets: SecretStore,
    private val hostKeys: HostKeyTrustStore,
    private val newId: () -> String = Server::newId,
) {

    /** Huella que este dispositivo ya confía para el endpoint del QR (`null` si ninguna). */
    fun trustedFingerprint(transfer: ServerTransfer): String? = hostKeys.trustedFingerprint(transfer.endpoint)

    suspend fun import(transfer: ServerTransfer): Server {
        val endpoint = transfer.endpoint
        if (transfer.conflictsWithTrustedHostKey(hostKeys.trustedFingerprint(endpoint))) {
            throw ServerTransfer.HostKeyConflictException(endpoint)
        }
        val server = Server(
            id = newId(),
            name = transfer.name,
            host = transfer.host,
            port = transfer.port,
            username = transfer.username,
            authMethod = AuthMethod.KEY,
            requiresPassphrase = false,
        )
        var trustedNow = false
        try {
            // Primero la clave: si no se puede guardar, no llega a existir el servidor.
            secrets.write(server.id, SecretKind.PRIVATE_KEY, transfer.privateKeyPem())
            trustedNow = trustIfUnknown(endpoint, transfer.hostKeyFingerprint)
            repository.upsert(server)
        } catch (error: Exception) {
            // También ante una cancelación: se limpia y se relanza tal cual.
            rollBack(server.id, endpoint.takeIf { trustedNow }, error)
            throw error
        }
        ArgosLog.info(ArgosLog.TAG_STORE, "Servidor ${server.id} importado desde el Mac")
        return server
    }

    /** Confía en [fingerprint] si el endpoint no tenía huella. `true` si la ha guardado ahora. */
    private fun trustIfUnknown(endpoint: String, fingerprint: String?): Boolean {
        if (fingerprint == null) return false
        return when (hostKeys.trustedFingerprint(endpoint)) {
            null -> {
                hostKeys.trust(endpoint, fingerprint)
                true
            }
            fingerprint -> false
            else -> throw ServerTransfer.HostKeyConflictException(endpoint)
        }
    }

    private fun rollBack(serverId: String, trustedEndpoint: String?, cause: Exception) {
        listOfNotNull(
            runCatching { secrets.deleteAll(serverId) }.exceptionOrNull(),
            trustedEndpoint?.let { runCatching { hostKeys.forget(it) }.exceptionOrNull() },
        ).forEach { failure ->
            ArgosLog.error(ArgosLog.TAG_STORE, "No se pudo deshacer la importación de $serverId", failure)
            cause.addSuppressed(failure)
        }
    }
}
