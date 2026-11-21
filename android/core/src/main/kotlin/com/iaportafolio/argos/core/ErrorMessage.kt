package com.iaportafolio.argos.core

/**
 * Punto único para convertir un error en texto de UI (port de `ArgosCore/ErrorMessage.swift`).
 *
 * Los errores tipados de Argos llevan su mensaje accionable en `message` (equivalente a
 * `errorDescription` de `LocalizedError`). Los de la librería SSH y de red que se escapen sin
 * traducir (llegan en inglés: «Timeout expired: 30000 MILLISECONDS», «Exhausted available
 * authentication methods»…) se explican en español con [TransportErrorText], como hace Apple
 * con `NIOSSHError`. Si no hay mensaje se cae al nombre del tipo.
 */
val Throwable.userMessage: String
    get() = TransportErrorText.describe(this)
        ?: localizedMessage?.takeIf { it.isNotBlank() }
        ?: (this::class.simpleName ?: "Error desconocido")

/**
 * Textos en español para errores de transporte (sshj, sockets) que no traen el suyo. Lógica pura
 * por nombre de clase (core no depende de sshj): solo actúa si el error de fuera es de esa
 * librería o de `java.net`; un `IOException` con texto propio se deja tal cual.
 */
object TransportErrorText {

    private const val SSHJ_PACKAGE = "net.schmizz."
    private const val NET_PACKAGE = "java.net."
    private const val MAX_CAUSE_DEPTH = 8

    const val CHANNEL_REJECTED =
        "El servidor rechazó abrir un canal SSH nuevo (¿demasiados canales abiertos en la conexión?). " +
            "Reintenta en unos segundos."
    const val AUTHENTICATION =
        "El servidor rechazó la autenticación. Revisa la contraseña o que la clave esté en " +
            "~/.ssh/authorized_keys del servidor. Las contraseñas no se sincronizan entre " +
            "dispositivos: si la cambiaste o funciona en otro, escríbela de nuevo en este."
    const val TIMEOUT = "El servidor no respondió a tiempo. Comprueba la red o que el servidor SSH esté en marcha."
    const val UNREACHABLE = "No se pudo conectar con el servidor. Comprueba la dirección, el puerto y la red."
    const val CONNECTION_CLOSED = "Se cortó la conexión SSH con el servidor. Reintenta."
    const val SFTP_PERMISSION = "El servidor no da permiso para esa operación por SFTP. Revisa los permisos de la ruta."
    const val SFTP_NOT_FOUND = "La ruta ya no existe en el servidor."

    /** Texto en español, o `null` si no es un error de transporte sin traducir. */
    fun describe(error: Throwable): String? {
        val name = error.javaClass.name
        if (!name.startsWith(SSHJ_PACKAGE) && !name.startsWith(NET_PACKAGE)) return null
        val chain = generateSequence(error) { it.cause?.takeIf { cause -> cause !== it } }.take(MAX_CAUSE_DEPTH).toList()
        val text = classify(chain) ?: return null
        val detail = error.message?.takeIf { it.isNotBlank() } ?: return text
        return "$text ($detail)"
    }

    private fun classify(chain: List<Throwable>): String? {
        val names = chain.map { it.javaClass.simpleName }
        val messages = chain.mapNotNull { it.message?.lowercase() }
        fun has(vararg simpleNames: String) = names.any { it in simpleNames }
        fun says(fragment: String) = messages.any { fragment in it }
        return when {
            has("OpenFailException") -> CHANNEL_REJECTED
            has("UserAuthException") -> AUTHENTICATION
            has("SFTPException") && says("permission denied") -> SFTP_PERMISSION
            has("SFTPException") && (says("no such file") || says("no such path")) -> SFTP_NOT_FOUND
            has("SocketTimeoutException", "TimeoutException") || says("timeout expired") -> TIMEOUT
            has("ConnectException", "NoRouteToHostException", "UnknownHostException") -> UNREACHABLE
            has("TransportException", "SocketException", "EOFException") || says("broken transport") ||
                says("connection reset") || says("broken pipe") -> CONNECTION_CLOSED
            else -> null
        }
    }
}
