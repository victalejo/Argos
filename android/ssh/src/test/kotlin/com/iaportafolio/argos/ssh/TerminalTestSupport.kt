package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.TerminalControlEvent
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.fail

/** Acumula la salida cruda del terminal tal como llega a `output` (bloque a bloque). */
class TerminalOutput {
    private val buffer = ByteArrayOutputStream()

    /** Bloques recibidos, en orden. */
    val chunks: MutableList<ByteArray> = CopyOnWriteArrayList()

    @Suppress("RedundantSuspendModifier") // Firma de `output: suspend (ByteArray) -> Unit`.
    suspend fun append(bytes: ByteArray) {
        synchronized(buffer) { buffer.write(bytes) }
        chunks += bytes
    }

    fun bytes(): ByteArray = synchronized(buffer) { buffer.toByteArray() }

    fun text(): String = bytes().toString(Charsets.UTF_8)

    /** Texto sin secuencias de escape (lo que tmux pinta, sin colores ni movimientos de cursor). */
    fun plainText(): String = text().replace(ANSI_ESCAPE, "")

    private companion object {
        val ANSI_ESCAPE = Regex("\u001B(\\[[0-?]*[ -/]*[@-~]|\\][^\u0007\u001B]*(\u0007|\u001B\\\\)|[()][0-9A-Za-z]|[=>78DEHMc])")
    }
}

/** Canal de control sin pérdidas: lo emitido antes de que el terminal lo recoja se conserva. */
fun controlChannel(): Channel<TerminalControlEvent> = Channel(Channel.UNLIMITED)

/** Teclas como bytes UTF-8. */
fun keys(text: String): TerminalControlEvent = TerminalControlEvent.Input(text.toByteArray(Charsets.UTF_8))

/** Espera (sondeando) a que [condition] se cumpla; falla con [description] si se agota el tiempo. */
suspend fun eventually(description: String, timeoutMillis: Long = 15_000, condition: () -> Boolean) {
    val deadline = System.nanoTime() + timeoutMillis * 1_000_000
    while (!condition()) {
        if (System.nanoTime() > deadline) fail("No se cumplió a tiempo: $description")
        delay(50)
    }
}

/** Hilos que siguen dentro del bombeo del terminal (lectores colgados = fuga). */
fun terminalReaderThreads(): List<String> = Thread.getAllStackTraces()
    .filter { (_, frames) -> frames.any { it.className.substringBefore('$') == SshjTerminal::class.java.name } }
    .map { (thread, _) -> thread.name }

/**
 * Proxy TCP local hacia `127.0.0.1:[targetPort]` para simular un corte de red: [close] cierra
 * los sockets de golpe, sin que el servidor llegue a cerrar ordenadamente los canales.
 */
class TcpProxy(private val targetPort: Int) : AutoCloseable {
    private val listener = ServerSocket(0, 0, InetAddress.getLoopbackAddress())
    private val sockets: MutableList<Socket> = CopyOnWriteArrayList()

    val port: Int get() = listener.localPort

    init {
        daemon("proxy-accept") {
            while (!listener.isClosed) {
                val client = runCatching { listener.accept() }.getOrNull() ?: break
                val upstream = Socket(InetAddress.getLoopbackAddress(), targetPort)
                sockets += client
                sockets += upstream
                daemon("proxy-up") { relay(client, upstream) }
                daemon("proxy-down") { relay(upstream, client) }
            }
        }
    }

    override fun close() {
        listener.close()
        sockets.forEach { socket -> runCatching { socket.close() } }
    }

    private fun relay(from: Socket, to: Socket) {
        try {
            from.getInputStream().copyTo(to.getOutputStream())
        } catch (_: IOException) {
            // Proxy cerrado: es justo el corte que se simula.
        } finally {
            runCatching { to.close() }
        }
    }

    private fun daemon(name: String, body: () -> Unit) {
        Thread(body, name).apply {
            isDaemon = true
            start()
        }
    }
}
