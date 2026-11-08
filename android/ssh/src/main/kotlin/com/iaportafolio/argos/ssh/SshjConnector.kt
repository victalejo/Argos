package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import net.schmizz.keepalive.KeepAliveProvider
import net.schmizz.sshj.Config
import net.schmizz.sshj.DefaultConfig
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security

/**
 * [SSHConnector] con sshj: fabrica un [SshjSSHService] por servidor. La conexión es perezosa
 * (se abre en la primera operación) y se reutiliza hasta [SSHServicing.disconnect].
 *
 * En Android, la app debe llamar a [installSecurityProvider] UNA vez al arrancar (en
 * `Application.onCreate`), antes de conectar.
 */
class SshjConnector(private val settings: Settings = Settings()) : SSHConnector {

    /**
     * Ajustes de red.
     *
     * @property connectTimeoutMillis tiempo máximo para abrir el socket TCP.
     * @property keepAliveIntervalSeconds intervalo de `keepalive@openssh.com`: más corto que
     *   los timeouts típicos de NAT/firewall (~60-120 s), como el heartbeat de 30 s de Apple.
     * @property keepAliveMaxMissed latidos sin respuesta tras los que sshj da la conexión por
     *   muerta (la siguiente operación reconecta).
     * @property channelCloseTimeoutSeconds espera máxima al cierre del canal tras leer la salida.
     */
    data class Settings(
        val connectTimeoutMillis: Int = 15_000,
        val keepAliveIntervalSeconds: Int = 30,
        val keepAliveMaxMissed: Int = 3,
        val channelCloseTimeoutSeconds: Long = 30,
    )

    override fun service(server: Server, credentials: SSHCredentials, trust: HostKeyTrustStore): SSHServicing =
        SshjSSHService(SshjConnection(server, credentials, trust, settings))

    companion object {
        private const val BC = "BC"

        /**
         * Registra el BouncyCastle COMPLETO como proveedor preferente. Android trae un "BC"
         * recortado (sin X25519, Ed25519, ChaCha20…) con el que sshj no puede negociar los
         * algoritmos modernos. Idempotente y seguro entre hilos.
         */
        @JvmStatic
        fun installSecurityProvider() {
            synchronized(this) {
                val current = Security.getProvider(BC)
                if (current?.javaClass?.name == BouncyCastleProvider::class.java.name &&
                    Security.getProviders().firstOrNull() === current
                ) {
                    return
                }
                Security.removeProvider(BC)
                Security.insertProviderAt(BouncyCastleProvider(), 1)
            }
        }

        /** Config de sshj con keep-alive real (`keepalive@openssh.com`), que detecta caídas. */
        internal fun config(): Config = DefaultConfig().apply {
            keepAliveProvider = KeepAliveProvider.KEEP_ALIVE
        }
    }
}
