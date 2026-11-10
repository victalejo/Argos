package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.ports.ActivePortForward
import com.iaportafolio.argos.core.ports.ListeningPort
import com.iaportafolio.argos.core.ports.ListeningPortParser
import com.iaportafolio.argos.core.ports.PortForwardException
import com.iaportafolio.argos.core.ports.PortForwardOperations
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
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
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/**
 * Reenvío de puertos local, como `ssh -L` (port de `ArgosCore/PortForwarding/` de Apple): escucha en
 * 127.0.0.1 del teléfono (nunca en la red local) y sshj abre un canal `direct-tcpip` por cada
 * conexión aceptada.
 *
 * Cada túnel usa su PROPIA conexión SSH ([SshjConnection.withDedicatedClient]): no compite por
 * canales con los comandos cortos y, al pararlo, cerrar esa conexión corta todas sus conexiones.
 * [SshjConnection.disconnect] también cierra las dedicadas; [stopAll] limpia los listeners.
 */
internal class SshjPortForwarding(private val connection: SshjConnection) : PortForwardOperations {

    private class Runtime(
        val info: ActivePortForward,
        val socket: ServerSocket,
        val job: Job,
        val client: AtomicReference<SSHClient?>,
    ) {
        val isHealthy: Boolean get() = !socket.isClosed && job.isActive && client.get()?.isConnected == true
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val forwards = LinkedHashMap<String, Runtime>()

    override suspend fun listeningPorts(): List<ListeningPort> =
        ListeningPortParser.parse(connection.capture(ListeningPortParser.command).stdout)

    override suspend fun startPortForward(remotePort: Int, targetHost: String, preferredLocalPort: Int): ActivePortForward {
        if (remotePort !in 1..65535) throw PortForwardException.invalidPort(remotePort)
        return mutex.withLock {
            if (forwards.values.any { it.info.remotePort == remotePort }) {
                throw PortForwardException.alreadyForwarded(remotePort)
            }
            open(UUID.randomUUID().toString(), remotePort, targetHost, preferredLocalPort).info
        }
    }

    override suspend fun stopPortForward(id: String) {
        val runtime = mutex.withLock { forwards.remove(id) } ?: return
        close(runtime)
    }

    /** Túneles activos. Si la conexión de alguno se cayó, lo reabre en el MISMO puerto local. */
    override suspend fun activePortForwards(): List<ActivePortForward> = mutex.withLock {
        for (runtime in forwards.values.toList().filterNot { it.isHealthy }) {
            forwards.remove(runtime.info.id)
            close(runtime)
            try {
                open(runtime.info.id, runtime.info.remotePort, runtime.info.targetHost, runtime.info.localPort)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Sin red: se reintenta en la siguiente consulta; el túnel desaparece de la lista.
            }
        }
        forwards.values.map { it.info }.sortedBy { it.remotePort }
    }

    suspend fun stopAll() {
        val all = mutex.withLock { forwards.values.toList().also { forwards.clear() } }
        all.forEach { close(it) }
    }

    // MARK: - Privado (con [mutex] tomado)

    private suspend fun open(id: String, remotePort: Int, targetHost: String, preferredLocalPort: Int): Runtime {
        val socket = bind(preferredLocalPort)
        val localPort = socket.localPort
        val ready = CompletableDeferred<Unit>()
        val client = AtomicReference<SSHClient?>(null)
        val job = scope.launch {
            try {
                connection.withDedicatedClient { ssh ->
                    client.set(ssh)
                    val forwarder = ssh.newLocalPortForwarder(
                        Parameters(LOOPBACK, localPort, targetHost, remotePort),
                        socket,
                    )
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
        val runtime = Runtime(ActivePortForward(id, remotePort, targetHost, localPort), socket, job, client)
        forwards[id] = runtime
        return runtime
    }

    /** Abre el listener en 127.0.0.1: el puerto pedido o, si está ocupado, uno libre. */
    private suspend fun bind(preferredLocalPort: Int): ServerSocket = withContext(Dispatchers.IO) {
        val loopback = InetAddress.getByName(LOOPBACK)
        val candidates = if (preferredLocalPort in 1..65535) listOf(preferredLocalPort, 0) else listOf(0)
        var lastError: IOException? = null
        for (port in candidates) {
            val socket = ServerSocket()
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
        } catch (_: IOException) {
            // Cerrar es best-effort.
        }
    }

    private companion object {
        const val LOOPBACK = "127.0.0.1"
        const val BACKLOG = 64
    }
}
