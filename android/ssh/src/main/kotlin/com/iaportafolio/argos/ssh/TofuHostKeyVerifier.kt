package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.HostKeyTrustStore
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import java.security.PublicKey
import java.util.concurrent.atomic.AtomicReference

/**
 * Verificación Trust-On-First-Use (port de `TOFUHostKeyValidator`): la primera conexión a
 * [endpoint] confía y guarda la huella; después DEBE coincidir o se aborta (posible MitM).
 *
 * sshj solo admite `true`/`false` y, al rechazar, lanza un `TransportException` genérico; por
 * eso el rechazo se recuerda en [mismatch] para que el conector lance
 * [HostKeyMismatchException] con las dos huellas.
 *
 * sshj la invoca desde su hilo de transporte: la comprobación y el guardado van bajo el
 * monitor de [trust] para que dos conexiones simultáneas no se pisen.
 */
internal class TofuHostKeyVerifier(
    private val endpoint: String,
    private val trust: HostKeyTrustStore,
) : HostKeyVerifier {

    private val rejected = AtomicReference<HostKeyMismatchException?>(null)

    /** Rechazo de la última verificación, si la huella no coincidía. */
    val mismatch: HostKeyMismatchException? get() = rejected.get()

    override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
        val presented = HostKeyFingerprint.of(key)
        synchronized(trust) {
            val stored = trust.trustedFingerprint(endpoint)
            return when (stored) {
                null -> {
                    trust.trust(endpoint, presented)
                    true
                }
                presented -> true
                else -> {
                    rejected.set(HostKeyMismatchException(endpoint, stored, presented))
                    false
                }
            }
        }
    }

    /** Sin preferencia de algoritmo: se negocia en el orden por defecto de sshj (Ed25519 primero). */
    override fun findExistingAlgorithms(hostname: String, port: Int): List<String> = emptyList()
}
