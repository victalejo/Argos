package com.iaportafolio.argos.ui.terminal

import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.data.MissingCredentialsException
import com.iaportafolio.argos.ssh.SshConnectionException

/** El servidor del terminal ya no existe (borrado con la pantalla abierta). */
class TerminalServerMissingException : Exception("Este servidor ya no existe.")

/** El servicio SSH no implementa [com.iaportafolio.argos.core.TerminalStreaming]. */
class TerminalStreamingUnavailableException :
    Exception("Esta conexión no admite terminales en vivo. Actualiza Argos e inténtalo de nuevo.")

/**
 * Reintentos del terminal cuando la conexión se cae (backoff exponencial con tope) y tiempos
 * del ciclo de vida. Pura: los tests la usan con tiempo virtual.
 */
data class ReconnectPolicy(
    /** Esperas entre intentos; el último valor se repite hasta [maxAttempts]. */
    val delaysMillis: List<Long> = listOf(1_000, 2_000, 4_000, 8_000, 15_000, 30_000),
    /** Reintentos automáticos seguidos antes de dejarlo en manos del usuario («Reconectar»). */
    val maxAttempts: Int = 8,
    /** Espera tras el último cambio de tamaño de la vista antes de enviar el `window-change`. */
    val resizeDebounceMillis: Long = 150,
    /** Cuánto se espera a que la vista mida su tamaño antes del primer attach (si no, 80x24). */
    val initialSizeWaitMillis: Long = 1_000,
) {
    init {
        require(delaysMillis.isNotEmpty()) { "Hace falta al menos una espera" }
    }

    /** Espera antes del reintento número [attempt] (0 = primer reintento). */
    fun delayFor(attempt: Int): Long = delaysMillis[attempt.coerceIn(0, delaysMillis.lastIndex)]

    /** ¿Tiene sentido reintentar solo? No si el fallo exige que el usuario haga algo. */
    fun isRetryable(error: Throwable): Boolean = causeChain(error).none { cause ->
        cause is HostKeyMismatchException ||
            cause is MissingCredentialsException ||
            cause is SshConnectionException.AuthenticationFailed ||
            cause is SSHServiceError ||
            cause is TerminalServerMissingException ||
            cause is TerminalStreamingUnavailableException
    }

    private fun causeChain(error: Throwable): Sequence<Throwable> =
        generateSequence(error) { current -> current.cause?.takeIf { it !== current } }.take(MAX_CAUSE_DEPTH)

    private companion object {
        const val MAX_CAUSE_DEPTH = 8
    }
}
