package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.agent.AgentExecException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedSendChannelException
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `sh -c '<script>'` (port de `ShellQuoting.posixShell`): los scripts de Argos son POSIX y deben
 * correr bajo `sh` aunque el shell de login sea zsh, donde un comodín sin coincidencias aborta.
 */
internal fun posixShell(script: String): String = "sh -c ${ShellQuoting.singleQuoted(script)}"

/**
 * Canal exec bidireccional del agente (port de `runAgentExec` de `Agent/SSHAgentExec.swift`): SIN
 * PTY (8-bit safe, sin secuencias de terminal) y en una conexión DEDICADA por llamada.
 *
 * Solo stdout llega a `output`; stderr se acumula para el error. Termina en cuanto acaba una de las
 * dos ramas: EOF del proceso o que `stdin` se complete. Como en Apple, un código de salida distinto
 * de 0 es un fallo: con stderr, [AgentExecException] con sus últimos [STDERR_DETAIL_LIMIT]
 * caracteres; sin él, [SSHServiceError.CommandFailed]. Si se corta la red,
 * [SshAgentChannelException]. Cancelar interrumpe las lecturas bloqueantes y cierra la conexión,
 * sin matar lo que corra en el servidor por su cuenta (el canal cerrado es EOF en su stdin).
 */
internal class SshjAgentExec(private val connection: SshjConnection) {

    suspend fun run(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
        val stderr = BoundedTail(STDERR_BUFFER_BYTES)
        try {
            connection.withDedicatedClient { ssh ->
                val running = start(ssh, posixShell(command))
                pump(ssh, running, stdin, output, stderr)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            // sshj convierte la interrupción en un error de E/S: la causa real es la cancelación.
            currentCoroutineContext().ensureActive()
            val detail = stderr.text().trim()
            if (detail.isNotEmpty()) throw AgentExecException(detail.takeLast(STDERR_DETAIL_LIMIT))
            throw error
        }
    }

    private suspend fun start(ssh: SSHClient, command: String): Session.Command = channelIo {
        ssh.startSession().exec(command)
    }

    /**
     * Dos lectores bloqueantes (en [Dispatchers.IO]): stdout va a un canal acotado (contrapresión)
     * que este bucle entrega a `output` en orden, en el contexto del llamador; stderr al búfer. El
     * escritor reenvía `stdin`. El canal se cierra con la primera rama que acabe.
     */
    private suspend fun pump(
        ssh: SSHClient,
        running: Session.Command,
        stdin: Flow<ByteArray>,
        output: suspend (ByteArray) -> Unit,
        stderr: BoundedTail,
    ) = coroutineScope {
        val chunks = Channel<ByteArray>(CHUNK_QUEUE_CAPACITY)
        val stdinFinished = AtomicBoolean(false)
        val readers = launch(Dispatchers.IO) {
            launch { readInto(running.inputStream, chunks) }
            launch { read(running.errorStream) { block -> stderr.append(block) } }
        }
        readers.invokeOnCompletion { chunks.close() }
        val writer = launch {
            if (forward(stdin, running)) {
                stdinFinished.set(true)
                chunks.close()
            }
        }
        for (chunk in chunks) output(chunk)
        writer.cancel()
        if (stdinFinished.get()) {
            readers.cancel()
        } else {
            checkExit(ssh, running)
        }
    }

    /**
     * Copia `stdin` al proceso; devuelve si se completó. Un fallo de escritura significa que el
     * proceso o la conexión se fueron: no es el fin de `stdin`, y son los lectores (EOF o error)
     * quienes informan del motivo real.
     */
    private suspend fun forward(stdin: Flow<ByteArray>, running: Session.Command): Boolean = try {
        val remote = running.outputStream
        stdin.collect { bytes ->
            blockingIo {
                remote.write(bytes)
                remote.flush()
            }
        }
        true
    } catch (_: IOException) {
        false
    }

    private suspend fun readInto(stream: InputStream, sink: SendChannel<ByteArray>) {
        try {
            read(stream) { block -> sink.send(block) }
        } catch (_: ClosedSendChannelException) {
            // `stdin` se completó: ya nadie espera esta salida.
        }
    }

    private suspend fun read(stream: InputStream, deliver: suspend (ByteArray) -> Unit) {
        val buffer = ByteArray(CHUNK_SIZE)
        while (true) {
            val count = channelIo { stream.read(buffer) }
            if (count < 0) return
            if (count > 0) deliver(buffer.copyOf(count))
        }
    }

    /** Tras el EOF: sin transporte, la conexión cayó; con código de salida distinto de 0, falló. */
    private suspend fun checkExit(ssh: SSHClient, running: Session.Command) {
        try {
            blockingIo { running.join(connection.channelCloseTimeoutSeconds, TimeUnit.SECONDS) }
        } catch (_: IOException) {
            // Sin el cierre a tiempo no hay código de salida; abajo se mira si queda transporte.
        }
        if (!ssh.isConnected) throw SshAgentChannelException(connection.endpoint)
        val code = running.exitStatus ?: return
        if (code != 0) throw SSHServiceError.CommandFailed(code, "el proceso no dejó detalle en stderr.")
    }

    /** E/S del canal: un fallo es [SshAgentChannelException] (salvo que se haya cancelado). */
    private suspend fun <T> channelIo(block: () -> T): T = try {
        blockingIo(block)
    } catch (error: IOException) {
        throw SshAgentChannelException(connection.endpoint, error)
    }

    /**
     * Llamada bloqueante de sshj en [Dispatchers.IO], interrumpible al cancelar. Si falla por la
     * cancelación se relanza la [CancellationException], nunca un error de E/S engañoso.
     */
    private suspend fun <T> blockingIo(block: () -> T): T = try {
        runInterruptible(Dispatchers.IO, block)
    } catch (error: IOException) {
        currentCoroutineContext().ensureActive()
        throw error
    }

    private companion object {
        /** Apple muestra los últimos 600 caracteres del stderr del agente. */
        const val STDERR_DETAIL_LIMIT = 600

        /** Final del stderr que se conserva: acota la memoria de un canal de días. */
        const val STDERR_BUFFER_BYTES = 64 * 1024

        const val CHUNK_SIZE = 16 * 1024
        const val CHUNK_QUEUE_CAPACITY = 8
    }
}

/** Últimos [capacity] bytes recibidos. Seguro entre hilos. */
private class BoundedTail(private val capacity: Int) {
    private val buffer = ByteArrayOutputStream()

    @Synchronized
    fun append(bytes: ByteArray) {
        buffer.write(bytes)
        if (buffer.size() > capacity) {
            val all = buffer.toByteArray()
            buffer.reset()
            buffer.write(all, all.size - capacity, capacity)
        }
    }

    @Synchronized
    fun text(): String = buffer.toByteArray().toString(Charsets.UTF_8)
}
