package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.keys.Ed25519Key
import com.iaportafolio.argos.core.keys.ServerTransfer
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.data.SecretStore
import java.io.IOException
import java.time.Instant

/** Instante fijo de los tests de importación. */
val IMPORT_NOW: Instant = Instant.ofEpochSecond(1_800_000_000)

const val QR_FINGERPRINT = "SHA256:Q3JlYWRvRW5FbE1hY1BhcmFFc3RlRGlzcG9zaXRpdm8"

/** Un QR del Mac como los de verdad (semilla aleatoria, comentario `argos-iphone-…`). */
fun transfer(
    host: String = "dev.example.com",
    port: Int = 22,
    username: String = "victor",
    fingerprint: String? = QR_FINGERPRINT,
    createdAt: Instant = IMPORT_NOW,
): ServerTransfer = ServerTransfer(
    name = "dev",
    host = host,
    port = port,
    username = username,
    keySeed = Ed25519Key.generate().seed,
    keyComment = ServerTransfer.makeKeyComment(),
    hostKeyFingerprint = fingerprint,
    createdAt = createdAt,
)

/** [SecretStore] que falla al escribir (disco lleno, Keystore no disponible…). */
class FailingSecretStore(private val delegate: InMemorySecretStore = InMemorySecretStore()) : SecretStore by delegate {
    val values get() = delegate.values
    val deletedAll get() = delegate.deletedAll
    var failWrites: Exception? = IOException("disco lleno")

    override fun write(serverId: String, kind: SecretKind, value: String) {
        failWrites?.let { throw it }
        delegate.write(serverId, kind, value)
    }
}

/** [HostKeyTrustStore] que cambia «por detrás» al leer (otra conexión confió entre medias). */
class RacingTrustStore(private val afterFirstRead: Pair<String, String>) : HostKeyTrustStore {
    val known = mutableMapOf<String, String>()
    private var reads = 0

    override fun trustedFingerprint(endpoint: String): String? {
        val value = known[endpoint]
        if (++reads == 1) known += afterFirstRead
        return value
    }

    override fun trust(endpoint: String, fingerprint: String) {
        known[endpoint] = fingerprint
    }

    override fun forget(endpoint: String) {
        known.remove(endpoint)
    }
}
