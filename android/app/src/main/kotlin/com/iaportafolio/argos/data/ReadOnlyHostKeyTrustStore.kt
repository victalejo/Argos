package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.HostKeyTrustStore

/** Un endpoint sin huella guardada no se conecta desde segundo plano. */
class UntrustedHostException(endpoint: String) :
    Exception("El servidor ($endpoint) no tiene huella guardada: conéctate desde la app para confiar en él.")

/**
 * [HostKeyTrustStore] para segundo plano: compara con las huellas guardadas y no añade ni cambia
 * ninguna. Nadie está mirando, así que no se debe confiar en nada nuevo.
 *
 * [trust] LANZA en vez de ignorar la petición: el verificador TOFU acepta la clave si `trust`
 * vuelve con normalidad. Aunque se comprueba antes de conectar, la huella se puede olvidar justo
 * entre medias, y entonces la conexión debe abortar.
 */
class ReadOnlyHostKeyTrustStore(private val delegate: HostKeyTrustStore) : HostKeyTrustStore {
    override fun trustedFingerprint(endpoint: String): String? = delegate.trustedFingerprint(endpoint)

    override fun trust(endpoint: String, fingerprint: String): Unit = throw UntrustedHostException(endpoint)

    override fun forget(endpoint: String) = Unit
}
