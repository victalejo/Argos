package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.PTYSize
import com.iaportafolio.argos.core.TerminalControlEvent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.PTYMode
import net.schmizz.sshj.connection.channel.direct.Session
import java.io.IOException
import java.io.InputStream

/**
 * Terminal en vivo sobre sshj (port de `runPTY` en `ArgosCore/SSHTerminalSession.swift`).
 *
 * Cada llamada abre una SESIÓN (canal) NUEVA sobre la conexión compartida de [connection]:
 * el mutex de la conexión solo se toma para obtener el cliente, así que el canal largo no
 * bloquea las operaciones de gestión que van en paralelo (cada una es otro canal).
 *
 * Flujo, idéntico a Apple: PTY `xterm-256color` (ECHO + ICRNL) con el tamaño inicial saneado
 * por [PTYSize.initial], shell interactivo y `exec <comando>\n` escrito en su stdin (al
 * terminar el comando, el canal se cierra limpiamente). Después:
 *
 * - salida (stdout y stderr) → `output`, en bloques de hasta [CHUNK_SIZE] bytes y SIN
 *   decodificar (un carácter UTF-8 puede quedar partido entre bloques; lo recompone el emulador);
 * - [TerminalControlEvent.Input] → stdin + flush; [TerminalControlEvent.Resize] →
 *   `window-change` (los tamaños transitorios que no pasan [PTYSize.isUsable] se descartan).
 *
 * Termina con normalidad en EOF (detach desde tmux, sesión matada, fin del comando). Si la
 * conexión cae lanza [SshTerminalException.ConnectionLost]; si no se puede abrir,
 * [SshTerminalException.OpenFailed] (o la [SshConnectionException] de la conexión). Al
 * cancelar, interrumpe las lecturas bloqueantes y cierra el canal (detach, NO kill).
 */
internal class SshjTerminal(private val connection: SshjConnection) {

    suspend fun run(
        launchCommand: String,
        initialCols: Int,
        initialRows: Int,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    ) {
        val ssh = connection.connectedClient()
        val session = openSession(ssh)
        try {
            val shell = startShell(ssh, session, PTYSize.initial(initialCols, initialRows), launchCommand)
            pump(ssh, shell, control, output)
        } finally {
            withContext(NonCancellable + Dispatchers.IO) { closeQuietly(session) }
        }
    }

    // MARK: Apertura

    private suspend fun openSession(ssh: SSHClient): Session = try {
        blockingIo { ssh.startSession() }
    } catch (error: IOException) {
        throw failure(ssh, error, opening = true)
    }

    private suspend fun startShell(
        ssh: SSHClient,
        session: Session,
        size: PTYSize.Dimensions,
        launchCommand: String,
    ): Session.Shell = try {
        blockingIo {
            session.allocatePTY(TERM, size.cols, size.rows, 0, 0, TERMINAL_MODES)
            session.startShell().also { shell ->
                // `exec` reemplaza el shell por el comando: al terminar (detach de tmux, fin del
                // comando) el canal se cierra limpiamente. Byte a byte como Apple.
                shell.outputStream.write("exec $launchCommand\n".toByteArray(Charsets.UTF_8))
                shell.outputStream.flush()
            }
        }
    } catch (error: IOException) {
        throw failure(ssh, error, opening = true)
    }

    // MARK: Bombeo

    /**
     * Dos lectores bloqueantes (stdout y stderr, en [Dispatchers.IO]) dejan los bloques en un
     * canal acotado (contrapresión); este bucle los entrega a `output` en orden, en el contexto
     * del llamador. El escritor reenvía [control] hasta que los lectores llegan al EOF.
     */
    private suspend fun pump(
        ssh: SSHClient,
        shell: Session.Shell,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    ) = coroutineScope {
        val chunks = Channel<ByteArray>(CHUNK_QUEUE_CAPACITY)
        val readers = launch(Dispatchers.IO) {
            launch { readInto(ssh, shell.inputStream, chunks) }
            launch { readInto(ssh, shell.errorStream, chunks) }
        }
        readers.invokeOnCompletion { chunks.close() }
        val writer = launch { forward(shell, control) }
        for (chunk in chunks) output(chunk)
        writer.cancelAndJoin()
        // EOF limpio pero sin transporte: la conexión cayó (algunos cortes llegan como cierre).
        if (!ssh.isConnected) throw SshTerminalException.ConnectionLost(connection.endpoint)
    }

    private suspend fun readInto(ssh: SSHClient, stream: InputStream, sink: SendChannel<ByteArray>) {
        val buffer = ByteArray(CHUNK_SIZE)
        while (true) {
            val read = try {
                blockingIo { stream.read(buffer) }
            } catch (error: IOException) {
                throw failure(ssh, error, opening = false)
            }
            if (read < 0) return
            if (read > 0) sink.send(buffer.copyOf(read))
        }
    }

    /**
     * Teclas → stdin (con flush) y tamaños → `window-change`. Si escribir falla, el canal se está
     * cerrando o la conexión cayó: se cierra el canal para que el lector termine y sea ÉL quien
     * informe del motivo real (EOF o [SshTerminalException.ConnectionLost]), nunca un terminal mudo.
     */
    private suspend fun forward(shell: Session.Shell, control: Flow<TerminalControlEvent>) {
        val stdin = shell.outputStream
        try {
            control.collect { event ->
                when (event) {
                    is TerminalControlEvent.Input -> blockingIo {
                        stdin.write(event.bytes)
                        stdin.flush()
                    }
                    is TerminalControlEvent.Resize -> if (PTYSize.isUsable(event.cols, event.rows)) {
                        blockingIo { shell.changeWindowDimensions(event.cols, event.rows, 0, 0) }
                    }
                }
            }
        } catch (_: IOException) {
            withContext(NonCancellable + Dispatchers.IO) { closeQuietly(shell) }
        }
    }

    // MARK: Utilidades

    /**
     * Llamada bloqueante de sshj en [Dispatchers.IO], interrumpible al cancelar. Si falla por la
     * cancelación (sshj convierte la interrupción en `InterruptedIOException`) se relanza la
     * [kotlinx.coroutines.CancellationException], nunca un error de E/S engañoso.
     */
    private suspend fun <T> blockingIo(block: () -> T): T = try {
        runInterruptible(Dispatchers.IO, block)
    } catch (error: IOException) {
        currentCoroutineContext().ensureActive()
        throw error
    }

    /** Sin transporte → conexión perdida; con transporte, falla la apertura o se cortó el canal. */
    private fun failure(ssh: SSHClient, error: IOException, opening: Boolean): Exception =
        if (opening && ssh.isConnected) {
            SshTerminalException.OpenFailed(connection.endpoint, error)
        } else {
            SshTerminalException.ConnectionLost(connection.endpoint, error)
        }

    private fun closeQuietly(channel: net.schmizz.sshj.connection.channel.Channel) {
        try {
            channel.close()
        } catch (_: IOException) {
            // El servidor ya lo cerró o la conexión cayó: no queda nada que liberar.
        }
    }

    private companion object {
        /** Terminal que se anuncia en el `pty-req` (como Apple). */
        const val TERM = "xterm-256color"

        /** Modos del PTY de Apple: `SSHTerminalModes([.ECHO: 1, .ICRNL: 1])`. */
        val TERMINAL_MODES: Map<PTYMode, Int> = mapOf(PTYMode.ECHO to 1, PTYMode.ICRNL to 1)

        /** Tamaño máximo de cada bloque entregado a `output`. */
        const val CHUNK_SIZE = 16 * 1024

        /** Bloques en vuelo entre los lectores y `output` antes de frenar la lectura. */
        const val CHUNK_QUEUE_CAPACITY = 8
    }
}
