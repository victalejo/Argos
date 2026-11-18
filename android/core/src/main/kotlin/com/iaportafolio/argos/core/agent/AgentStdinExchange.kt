package com.iaportafolio.argos.core.agent

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream

/**
 * Piezas del cliente del agente persistente (port de `ArgosCore/Agent/AgentStdinExchange.swift`):
 * el intercambio «mando bytes por stdin y espero UNA línea de respuesta» (lanzar con el token,
 * enviar líneas grandes), el estado de la conexión al log y la espera entre reintentos.
 */
object AgentStdinExchange {

    /** Plazo por defecto para recibir la respuesta. */
    const val DEFAULT_TIMEOUT_MILLIS = 45_000L

    /**
     * Ejecuta [command] por un canal exec, le escribe [input] por stdin y devuelve la primera
     * línea de stdout que [accept] reconozca (las anteriores, p. ej. ruido del perfil del shell,
     * se ignoran). stdin se cierra en cuanto llega. Si no llega en [timeoutMillis], se cancela el
     * canal y se lanza [AgentExchangeTimeoutException].
     */
    suspend fun firstLine(
        exec: AgentExecStreaming,
        command: String,
        input: ByteArray,
        timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
        accept: (String) -> Boolean = { it.isNotEmpty() },
    ): String = coroutineScope {
        val stdin = Channel<ByteArray>(Channel.UNLIMITED)
        stdin.trySend(input)
        val pending = ByteArrayOutputStream()
        val accepted = CompletableDeferred<String>()
        val finished = CompletableDeferred<Exception?>()
        val run = launch {
            val failure = try {
                exec.runAgentExec(command, stdin.receiveAsFlow()) { chunk ->
                    if (!accepted.isCompleted) {
                        consume(chunk, pending, accept)?.let { line ->
                            accepted.complete(line)
                            stdin.close()
                        }
                    }
                }
                null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                error
            }
            finished.complete(failure)
        }
        val ended = withTimeoutOrNull(timeoutMillis) { finished.await() }
        stdin.close()
        val timedOut = !finished.isCompleted
        if (timedOut) run.cancel()
        if (accepted.isCompleted) return@coroutineScope accepted.await()
        val leftover = SwiftText.trimWhitespaceAndNewlines(pending.toByteArray().toString(Charsets.UTF_8))
        if (leftover.isNotEmpty() && accept(leftover)) return@coroutineScope leftover
        if (timedOut) throw AgentExchangeTimeoutException()
        throw ended ?: AgentExecException("El servidor no respondió.")
    }

    /** Añade [chunk] y devuelve la primera línea completa aceptada (descarta las anteriores). */
    private fun consume(chunk: ByteArray, pending: ByteArrayOutputStream, accept: (String) -> Boolean): String? {
        pending.write(chunk)
        var bytes = pending.toByteArray()
        var accepted: String? = null
        var newline = bytes.indexOf(NEWLINE)
        while (newline >= 0 && accepted == null) {
            val line = SwiftText.trimWhitespace(bytes.copyOfRange(0, newline).toString(Charsets.UTF_8))
            bytes = bytes.copyOfRange(newline + 1, bytes.size)
            if (accept(line)) accepted = line
            newline = bytes.indexOf(NEWLINE)
        }
        pending.reset()
        pending.write(bytes)
        return accepted
    }

    private const val NEWLINE: Byte = 0x0A
}

/** El servidor no contestó a tiempo (conexión colgada o comando bloqueado). */
class AgentExchangeTimeoutException :
    Exception("El servidor no respondió a tiempo. Comprueba la conexión y vuelve a intentarlo.")

/** Estado REAL de la conexión al log de un agente persistente (para la interfaz). */
sealed interface AgentLinkState {
    /** No se está leyendo (vista cerrada, segundo plano). */
    data object Detached : AgentLinkState

    /** Abriendo el canal; aún no ha llegado nada. */
    data object Connecting : AgentLinkState

    /** Leyendo el log en vivo. */
    data object Live : AgentLinkState

    /** El flujo se cortó: se reintenta solo ([attempt] empieza en 1). */
    data class Reconnecting(val attempt: Int) : AgentLinkState
}

/** Espera exponencial entre reintentos de enganche: 1, 2, 4, 8, 16 y luego 30 s. */
object AgentReconnectPolicy {
    const val MAX_DELAY_SECONDS = 30

    fun delaySeconds(attempt: Int): Int {
        if (attempt <= 1) return 1
        val exponent = minOf(attempt - 1, 5)
        return minOf(MAX_DELAY_SECONDS, 1 shl exponent)
    }
}

/** Resultado de enviar un mensaje a un agente persistente. */
enum class AgentSendOutcome {
    /** Llegó al agente: ya se puede vaciar el borrador. */
    SENT,

    /** No llegó (el motivo queda en `lastError`): el borrador se conserva. */
    FAILED,

    /** Hibernado en un modo que actúa sin preguntar: hay que confirmar la reanudación. */
    NEEDS_RESUME_CONFIRMATION,
}
