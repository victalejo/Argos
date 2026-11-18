package com.iaportafolio.argos.ssh

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import net.schmizz.sshj.connection.channel.OpenFailException
import net.schmizz.sshj.transport.TransportException
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeoutException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * Tope de canales cortos simultáneos sobre la conexión compartida (port de
 * `ArgosCore/ChannelGate.swift`). OpenSSH admite `MaxSessions` (10 por defecto) canales por
 * conexión; los sondeos, git, puertos y las subidas podían coincidir y pasarse, y el servidor
 * rechazaba el canal («open failed»). Quien llega con el cupo lleno espera su turno (FIFO).
 */
internal class ChannelGate(limit: Int = SHARED_CONNECTION_LIMIT) {
    val limit: Int = maxOf(1, limit)
    private val semaphore = Semaphore(this.limit)

    /** Canales cortos en curso ahora mismo. */
    val activeCount: Int get() = limit - semaphore.availablePermits

    suspend fun <T> withPermit(block: suspend () -> T): T = semaphore.withPermit { block() }

    companion object {
        /** Deja margen bajo `MaxSessions` para el SFTP persistente y los terminales. */
        const val SHARED_CONNECTION_LIMIT = 6
    }
}

/**
 * Reintentos cuando el servidor rechaza ABRIR un canal: el comando nunca llegó a ejecutarse, así
 * que repetirlo es seguro (port de `ChannelRetry`).
 */
internal object ChannelRetry {
    const val MAX_ATTEMPTS = 4

    /** Espera antes del reintento [attempt] (1, 2, 3…): crece para dar tiempo a que se cierren canales. */
    fun delay(attempt: Int): Duration = (300L * attempt).milliseconds

    fun isRejection(error: Throwable): Boolean = causes(error).any { it is OpenFailException }
}

/**
 * Plazos por comando del canal de comandos: una captura colgada (conexión medio abierta, comando
 * que no termina) retendría su canal para siempre.
 */
internal object CommandTimeouts {
    /** Por defecto: sondeos, tmux, lecturas cortas. */
    val SHORT: Duration = 30.seconds

    /** Listados que recorren mucho (índice de archivos, resúmenes git, `gh` con red). */
    val MEDIUM: Duration = 2.minutes

    /** Trabajo largo explícito: clonar, push/pull, commit con hooks, instalar paquetes. */
    val LONG: Duration = 15.minutes

    /** Sonda de salud de la conexión (volver a primer plano, cambio de red). */
    val PROBE: Duration = 4.seconds
}

/**
 * Abre un canal (sesión, SFTP) SIN interrumpir la apertura: en sshj, abrir registra el canal,
 * envía `CHANNEL_OPEN` y espera la confirmación; si se interrumpe a mitad, el canal queda abierto
 * en el servidor y nadie lo cierra (tras horas de sondeos cancelados se agota `MaxSessions`).
 *
 * La apertura corre en [scope] (desacoplada del llamador): si el llamador se cancela, se le libera
 * al momento y el canal se cierra en cuanto termine de abrirse.
 */
internal suspend fun <C : Closeable> CoroutineScope.openChannelDetached(open: () -> C): C {
    val pending = async { open() }
    try {
        return pending.await()
    } catch (cancelled: CancellationException) {
        launch { runCatching { pending.await() }.getOrNull()?.let(::closeChannelQuietly) }
        throw cancelled
    }
}

internal fun closeChannelQuietly(channel: Closeable) {
    try {
        channel.close()
    } catch (_: IOException) {
        // El servidor ya lo cerró o la conexión cayó: no queda nada que liberar.
    }
}

/**
 * Traduce un fallo de E/S de sshj en un comando ya conectado a una excepción con mensaje en
 * español (la UI muestra `message`). Lo que no se reconoce se devuelve tal cual.
 */
internal fun translateTransportError(error: IOException, endpoint: String, stillConnected: Boolean): Exception {
    val chain = causes(error).toList()
    return when {
        chain.any { it is OpenFailException } -> SshChannelRejectedException(endpoint, error)
        chain.any { it is SocketTimeoutException || it is TimeoutException } -> SshConnectionException.Timeout(endpoint, error)
        chain.any { it is SocketException || it is EOFException || it is TransportException } ->
            SshConnectionException.ConnectionClosed(endpoint, error)
        // Cualquier otro fallo de sshj sin transporte debajo: se cortó la conexión.
        !stillConnected -> SshConnectionException.ConnectionClosed(endpoint, error)
        else -> error
    }
}

private const val MAX_CAUSE_DEPTH = 8

internal fun causes(error: Throwable): Sequence<Throwable> =
    generateSequence(error) { current -> current.cause?.takeIf { it !== current } }.take(MAX_CAUSE_DEPTH)
