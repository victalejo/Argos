package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.ConnectionPriority
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
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
 * rechazaba el canal («open failed»). Quien llega con el cupo lleno espera su turno.
 *
 * - Dos clases de turno: el usuario tiene preferencia y el fondo, un cupo menor
 *   ([backgroundLimit]), para que una acción no espere detrás de los sondeos.
 * - Esperar es cancelable: una corrutina cancelada sale de la cola sin ocupar turno.
 * - Límite adaptativo: si el servidor rechaza un canal, el tope baja para esa conexión (con suelo
 *   en 1: servidores con `MaxSessions 1`) y vuelve al de partida con la siguiente ([resetLimit]).
 */
internal class ChannelGate(limit: Int = SHARED_CONNECTION_LIMIT) {
    /** Tope de partida (el adaptativo nunca lo supera). */
    val limit: Int = maxOf(1, limit)

    private val lock = Any()
    private var current: Int = this.limit
    private val inUse = IntArray(ConnectionPriority.entries.size)
    private val waiters = ArrayDeque<Waiter>()

    private class Waiter(val priority: ConnectionPriority, val granted: CompletableDeferred<Unit> = CompletableDeferred())

    /** Tope vigente para la conexión actual. */
    val currentLimit: Int get() = synchronized(lock) { current }

    /** Canales cortos en curso ahora mismo. */
    val activeCount: Int get() = synchronized(lock) { inUse.sum() }

    fun activeCount(priority: ConnectionPriority): Int = synchronized(lock) { inUse[priority.ordinal] }

    /** Canales que puede ocupar a la vez el trabajo de fondo (la mitad del tope). */
    private val backgroundLimit: Int get() = maxOf(1, current / 2)

    /** Espera turno. Si la corrutina se cancela mientras espera, NO ocupa turno. */
    suspend fun acquire(priority: ConnectionPriority) {
        val waiter = synchronized(lock) {
            if (canAdmit(priority)) {
                inUse[priority.ordinal] += 1
                null
            } else {
                Waiter(priority).also(waiters::addLast)
            }
        } ?: return
        try {
            waiter.granted.await()
        } catch (cancelled: CancellationException) {
            // Si ya se le había dado turno (carrera con la cancelación), se devuelve.
            val wasGranted = synchronized(lock) { !waiters.remove(waiter) }
            if (wasGranted) release(priority)
            throw cancelled
        }
    }

    fun release(priority: ConnectionPriority) {
        val granted = synchronized(lock) {
            inUse[priority.ordinal] = maxOf(0, inUse[priority.ordinal] - 1)
            dispatchLocked()
        }
        granted.forEach { it.granted.complete(Unit) }
    }

    suspend fun <T> withPermit(priority: ConnectionPriority, block: suspend () -> T): T {
        acquire(priority)
        try {
            return block()
        } finally {
            release(priority)
        }
    }

    /**
     * El servidor rechazó un canal con [activeCount] abiertos (contando el rechazado): el tope baja
     * a uno menos y se recuerda para esta conexión. Devuelve el nuevo tope.
     */
    fun lowerLimitAfterRejection(): Int = synchronized(lock) {
        val floor = minOf(limit, MINIMUM_ADAPTIVE_LIMIT)
        val candidate = maxOf(floor, minOf(current, inUse.sum()) - 1)
        if (candidate < current) current = candidate
        current
    }

    /** Conexión nueva: se vuelve al tope de partida. */
    fun resetLimit() {
        val granted = synchronized(lock) {
            current = limit
            dispatchLocked()
        }
        granted.forEach { it.granted.complete(Unit) }
    }

    private fun canAdmit(priority: ConnectionPriority): Boolean {
        if (inUse.sum() >= current) return false
        return priority == ConnectionPriority.USER || inUse[ConnectionPriority.BACKGROUND.ordinal] < backgroundLimit
    }

    /** Entrega turnos libres: primero al usuario (en orden de llegada), luego al fondo. */
    private fun dispatchLocked(): List<Waiter> {
        val granted = mutableListOf<Waiter>()
        while (true) {
            val next = waiters.firstOrNull { it.priority == ConnectionPriority.USER && canAdmit(it.priority) }
                ?: waiters.firstOrNull { it.priority == ConnectionPriority.BACKGROUND && canAdmit(it.priority) }
                ?: break
            waiters.remove(next)
            inUse[next.priority.ordinal] += 1
            granted += next
        }
        return granted
    }

    companion object {
        /** Deja margen bajo `MaxSessions` para el SFTP persistente y los terminales. */
        const val SHARED_CONNECTION_LIMIT = 6

        /** Hasta 1: con `MaxSessions 1` (configuración endurecida) es lo único que funciona. */
        private const val MINIMUM_ADAPTIVE_LIMIT = 1
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

    /**
     * Comandos vencidos cuyo canal sigue abierto a partir de los cuales se recicla la conexión
     * compartida (antes de agotar `MaxSessions`).
     */
    const val ABANDONED_CHANNEL_LIMIT = 3
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
