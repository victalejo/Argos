package com.iaportafolio.argos.core

/**
 * Contrato de conexión SSH compartido por el módulo `ssh` (implementación con sshj) y la app
 * (que lee los secretos del almacén seguro y persiste las huellas TOFU).
 *
 * Equivale a `Server.makeService()` + `SSHService.Configuration` + `TOFUHostKeyValidator` de
 * Apple, pero sin acoplar `core` a ningún almacenamiento concreto.
 */

/** Secretos para autenticar, ya leídos del almacén seguro por la plataforma. */
sealed interface SSHCredentials {

    /** Usuario + contraseña ([Server.authMethod] == [AuthMethod.PASSWORD]). */
    class Password(val password: String) : SSHCredentials {
        override fun toString(): String = "Password(***)"
    }

    /**
     * Clave privada en formato OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`). Se pasa el
     * CONTENIDO, no una ruta: en Android la clave importada vive cifrada con el Keystore y
     * nunca se escribe en claro en disco.
     */
    class PrivateKey(val openSSHPem: String, val passphrase: String?) : SSHCredentials {
        override fun toString(): String = "PrivateKey(***)"
    }
}

/**
 * Almacén TOFU de huellas de host key: endpoint `host:port` → `SHA256:<base64 sin padding>`
 * (mismo formato que OpenSSH y que el `known_hosts.json` de Apple, para que las huellas que
 * llegan por el QR de `ServerTransfer` sean comparables).
 *
 * Las implementaciones deben ser seguras entre hilos: la verificación ocurre en el hilo de
 * transporte del cliente SSH.
 */
interface HostKeyTrustStore {
    fun trustedFingerprint(endpoint: String): String?
    fun trust(endpoint: String, fingerprint: String)
    fun forget(endpoint: String)
}

/**
 * La host key presentada no coincide con la confiada: posible MitM o servidor reinstalado.
 * Mismo texto que `HostKeyMismatchError` de Apple, adaptado a la acción de Android.
 */
class HostKeyMismatchException(
    val endpoint: String,
    val storedFingerprint: String,
    val presentedFingerprint: String,
) : Exception(
    "La identidad del servidor ($endpoint) cambió. " +
        "Esperada $storedFingerprint, recibida $presentedFingerprint. " +
        "Posible ataque MitM: conexión abortada. Si el cambio es legítimo " +
        "(p. ej. reinstalaste el servidor), usa «Olvidar host key» en el servidor.",
)

/**
 * Fabrica el servicio de un servidor. La conexión es perezosa (como `connectedClient()` en
 * Apple): se abre en la primera llamada y se reutiliza; [SSHServicing.disconnect] la cierra.
 */
fun interface SSHConnector {
    fun service(server: Server, credentials: SSHCredentials, trust: HostKeyTrustStore): SSHServicing
}
