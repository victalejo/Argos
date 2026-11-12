package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.ports.ActivePortForward
import com.iaportafolio.argos.core.ports.ListeningPort
import com.iaportafolio.argos.core.ports.ListeningPortParser
import com.iaportafolio.argos.core.ports.PortForwardActivity
import com.iaportafolio.argos.core.ports.PortForwardDevice
import com.iaportafolio.argos.core.ports.PortForwardException
import com.iaportafolio.argos.core.ports.PortForwardIdlePolicy
import com.iaportafolio.argos.core.ports.PortForwardOperations
import com.iaportafolio.argos.core.ports.PortForwardRequest
import com.iaportafolio.argos.core.ports.PortForwardRequestParser
import com.iaportafolio.argos.core.ports.PortForwardServerFiles
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Parameters
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Reenvío de puertos local, como `ssh -L` (port de `ArgosCore/PortForwarding/` de Apple): escucha en
 * 127.0.0.1 del teléfono (nunca en la red local) y sshj abre un canal `direct-tcpip` por cada
 * conexión aceptada.
 *
 * Cada túnel usa su PROPIA conexión SSH ([SshjConnection.withDedicatedClient]). Mientras haya
 * túneles, un vigilante (cada [watchIntervalMillis]) cierra los que llevan el límite de
 * [PortForwardIdlePolicy] sin conexiones, reabre los caídos y mantiene al día en el servidor el
 * archivo de este teléfono para la skill de Claude (`argos-ports`).
 */
internal class SshjPortForwarding(
    private val connection: SshjConnection,
    private val watchIntervalMillis: Long = WATCH_INTERVAL_MILLIS,
    private val clock: () -> Long = System::currentTimeMillis,
) : PortForwardOperations {

    private class Runtime(
        val info: ActivePortForward,
        val socket: ServerSocket,
        val job: Job,
        val client: AtomicReference<SSHClient?>,
        val activity: PortForwardActivity,
    ) {
        val isHealthy: Boolean get() = !socket.isClosed && job.isActive && client.get()?.isConnected == true
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val forwards = LinkedHashMap<String, Runtime>()

    /** Túneles caídos que aún no se han podido reabrir: se reintentan en cada pasada. */
    private val broken = LinkedHashMap<String, ActivePortForward>()

    /** Hay una reapertura en curso. Se lee y escribe con [mutex] tomado. */
    private var reopening = false
    private var watcher: Job? = null
    private var toolChecked = false
    private var publishedAt: Long? = null

    override suspend fun listeningPorts(): List<ListeningPort> {
        val result = connection.capture(ListeningPortParser.command)
        ensurePortsTool()
        return ListeningPortParser.parse(result.stdout)
    }

    override suspend fun startPortForward(remotePort: Int, targetHost: String, preferredLocalPort: Int): ActivePortForward {
        if (remotePort !in 1..65535) throw PortForwardException.invalidPort(remotePort)
        val info = mutex.withLock {
            if (forwards.values.any { it.info.remotePort == remotePort } || broken.values.any { it.remotePort == remotePort }) {
                throw PortForwardException.alreadyForwarded(remotePort)
            }
            open(UUID.randomUUID().toString(), remotePort, targetHost, preferredLocalPort).info
        }
        ensurePortsTool()
        publish()
        startWatcher()
        return info
    }

    override suspend fun stopPortForward(id: String) {
        val runtime = mutex.withLock {
            broken.remove(id)
            forwards.remove(id)
        } ?: return
        close(runtime)
        publish()
    }

    /**
     * Túneles activos. Si la conexión de alguno se cayó, lo reabre en el MISMO puerto local. El
     * que no se puede reabrir todavía sigue en la lista ([ActivePortForward.isReconnecting]) y se
     * reintenta en la siguiente pasada.
     */
    override suspend fun activePortForwards(): List<ActivePortForward> {
        val changed = reopenUnhealthy()
        if (changed) publish()
        return mutex.withLock {
            (forwards.values.map { it.info } + broken.values.map { it.copy(isReconnecting = true) })
                .sortedBy { it.remotePort }
        }
    }

    /** Cierra todos (al desconectar) y borra el archivo del servidor si la conexión sigue viva. */
    suspend fun stopAll() {
        watcher?.cancel()
        watcher = null
        val all = mutex.withLock {
            broken.clear()
            forwards.values.toList().also { forwards.clear() }
        }
        all.forEach { close(it) }
        if (all.isNotEmpty()) bestEffort(PortForwardServerFiles.unpublishCommand(PortForwardDevice.id))
        publishedAt = null
    }

    /** Solicitudes pendientes (`argos-ports open`). Las caducadas se borran y no se devuelven. */
    override suspend fun pendingPortForwardRequests(): List<PortForwardRequest> =
        PortForwardRequestParser.parse(connection.capture(PortForwardServerFiles.listRequestsCommand).stdout)

    /** Retira una solicitud (aceptada o rechazada). Best-effort. */
    override suspend fun dismissPortForwardRequest(port: Int) {
        bestEffort(PortForwardServerFiles.dismissRequestCommand(port))
    }

    /** Conexiones abiertas ahora mismo por un túnel (para los tests). */
    internal suspend fun activeConnections(id: String): Int? = mutex.withLock { forwards[id]?.activity?.snapshot()?.first }

    // MARK: - Vigilante

    private fun startWatcher() {
        if (watcher?.isActive == true) return
        watcher = scope.launch {
            while (true) {
                delay(watchIntervalMillis)
                if (!watchOnce()) break
            }
        }
    }

    /** Una pasada. Devuelve `false` cuando ya no quedan túneles (el vigilante termina). */
    internal suspend fun watchOnce(): Boolean {
        val now = clock()
        val limit = PortForwardIdlePolicy.limitMinutes
        val idle = mutex.withLock {
            forwards.values.filter { runtime ->
                val (active, last) = runtime.activity.snapshot()
                PortForwardIdlePolicy.shouldClose(active, last, now, limit)
            }.onEach { forwards.remove(it.info.id) }
        }
        idle.forEach { close(it) }
        val reopened = reopenUnhealthy()
        val stale = publishedAt?.let { now - it >= PortForwardServerFiles.REFRESH_INTERVAL_MILLIS } ?: true
        if (idle.isNotEmpty() || reopened || stale) publish()
        return mutex.withLock { forwards.isNotEmpty() || broken.isNotEmpty() }
    }

    // MARK: - Archivos del servidor (skill de Claude)

    private suspend fun publish() {
        val current = mutex.withLock { forwards.values.map { it.info } }
        val command = if (current.isEmpty()) {
            PortForwardServerFiles.unpublishCommand(PortForwardDevice.id)
        } else {
            PortForwardServerFiles.publishCommand(PortForwardDevice.id, PortForwardDevice.name, current)
        }
        if (bestEffort(command)) publishedAt = if (current.isEmpty()) null else clock()
    }

    /** Instala (una vez por conexión) el script `argos-ports` y la skill de Claude. */
    private suspend fun ensurePortsTool() {
        if (toolChecked) return
        toolChecked = true
        if (!bestEffort(PortForwardServerFiles.installCommand)) toolChecked = false
    }

    private suspend fun bestEffort(command: String): Boolean = try {
        connection.captureIfConnected(command)?.exitCode == 0
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        false
    }

    // MARK: - Túneles

    /**
     * Reabre en su mismo puerto los túneles cuya conexión se cayó. Los que no se pueden reabrir
     * (sin red todavía) quedan en [broken] para la siguiente pasada. Devuelve si cambió algo.
     *
     * Conectar va FUERA del [mutex]: sin red cada intento dura hasta el timeout de conexión, y
     * con el mutex tomado no se podría ni parar un túnel ni pintar la lista entretanto.
     */
    private suspend fun reopenUnhealthy(): Boolean {
        val (fallen, pending) = mutex.withLock {
            val fallen = forwards.values.toList().filterNot { it.isHealthy }
            for (runtime in fallen) {
                forwards.remove(runtime.info.id)
                broken[runtime.info.id] = runtime.info
            }
            // Una sola reapertura a la vez (la piden el vigilante y la pantalla).
            val pending = if (reopening) emptyList() else broken.values.toList().also { reopening = it.isNotEmpty() }
            fallen to pending
        }
        fallen.forEach { close(it) }
        if (pending.isEmpty()) return fallen.isNotEmpty()

        var reopened = false
        try {
            for (info in pending) {
                val runtime = try {
                    connect(info.id, info.remotePort, info.targetHost, info.localPort)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    continue // Sin red: sigue en `broken` y se reintenta en la siguiente pasada.
                }
                // Si lo pararon mientras se reabría, no debe resucitar.
                val adopted = mutex.withLock {
                    (broken.remove(info.id) != null).also { stillWanted -> if (stillWanted) forwards[info.id] = runtime }
                }
                if (adopted) reopened = true else close(runtime)
            }
        } finally {
            // Aunque cancelen a mitad: si no, nunca más se reabriría nada.
            withContext(NonCancellable) { mutex.withLock { reopening = false } }
        }
        return fallen.isNotEmpty() || reopened
    }

    /** Abre un túnel y lo registra. Llamar con [mutex] tomado. */
    private suspend fun open(id: String, remotePort: Int, targetHost: String, preferredLocalPort: Int): Runtime =
        connect(id, remotePort, targetHost, preferredLocalPort).also { forwards[id] = it }

    private suspend fun connect(id: String, remotePort: Int, targetHost: String, preferredLocalPort: Int): Runtime {
        val activity = PortForwardActivity(clock())
        val socket = bind(preferredLocalPort, activity)
        val localPort = socket.localPort
        val ready = CompletableDeferred<Unit>()
        val client = AtomicReference<SSHClient?>(null)
        val job = scope.launch {
            try {
                connection.withDedicatedClient { ssh ->
                    client.set(ssh)
                    val forwarder = ssh.newLocalPortForwarder(Parameters(LOOPBACK, localPort, targetHost, remotePort), socket)
                    ready.complete(Unit)
                    // `accept()` no atiende interrupciones: se desbloquea al cerrar el socket.
                    runInterruptible { forwarder.listen() }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ready.completeExceptionally(e)
            } finally {
                closeQuietly(socket)
            }
        }
        try {
            ready.await()
        } catch (e: Throwable) {
            // Fallo al conectar o cancelación: no dejar el puerto abierto.
            job.cancel()
            closeQuietly(socket)
            throw e
        }
        return Runtime(ActivePortForward(id, remotePort, targetHost, localPort), socket, job, client, activity)
    }

    /** Abre el listener en 127.0.0.1: el puerto pedido o, si está ocupado, uno libre. */
    private suspend fun bind(preferredLocalPort: Int, activity: PortForwardActivity): ServerSocket = withContext(Dispatchers.IO) {
        val loopback = InetAddress.getByName(LOOPBACK)
        val candidates = if (preferredLocalPort in 1..65535) listOf(preferredLocalPort, 0) else listOf(0)
        var lastError: IOException? = null
        for (port in candidates) {
            val socket = TrackingServerSocket(activity, clock)
            try {
                socket.reuseAddress = true
                socket.bind(InetSocketAddress(loopback, port), BACKLOG)
                return@withContext socket
            } catch (e: IOException) {
                closeQuietly(socket)
                lastError = e
            }
        }
        throw PortForwardException.bindFailed(lastError?.message ?: "error desconocido")
    }

    private suspend fun close(runtime: Runtime) {
        withContext(Dispatchers.IO) {
            closeQuietly(runtime.socket)
            runtime.client.get()?.let(::closeQuietly)
        }
        runtime.job.cancel()
    }

    private fun closeQuietly(closeable: java.io.Closeable) {
        try {
            closeable.close()
        } catch (_: Exception) {
            // Cerrar es best-effort. Además de IOException, sshj puede lanzar
            // ConcurrentModificationException si otro hilo cierra a la vez un canal (visto en CI).
        }
    }

    /** Cuenta cada conexión aceptada mientras siga abierta (sshj cierra el socket al terminar). */
    private class TrackingServerSocket(
        private val activity: PortForwardActivity,
        private val clock: () -> Long,
    ) : ServerSocket() {
        override fun accept(): Socket {
            if (isClosed) throw SocketException("Socket is closed")
            val socket = TrackingSocket(activity, clock)
            implAccept(socket)
            activity.connectionOpened(clock())
            socket.counted.set(true)
            return socket
        }
    }

    private class TrackingSocket(private val activity: PortForwardActivity, private val clock: () -> Long) : Socket() {
        /** Solo se descuenta si llegó a contarse (un `implAccept` fallido no cuenta). */
        val counted = AtomicBoolean(false)

        override fun close() {
            try {
                super.close()
            } finally {
                if (counted.compareAndSet(true, false)) activity.connectionClosed(clock())
            }
        }
    }

    internal companion object {
        const val LOOPBACK = "127.0.0.1"
        const val BACKLOG = 64
        const val WATCH_INTERVAL_MILLIS = 30_000L
    }
}
