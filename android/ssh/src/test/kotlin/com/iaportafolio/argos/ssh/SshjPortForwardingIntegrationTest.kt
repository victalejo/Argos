package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.ports.PortForwardException
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.Executors
import kotlin.concurrent.thread
import kotlin.random.Random
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Reenvío de puertos de punta a punta: un socket local del «teléfono» → túnel sshj → MINA SSHD
 * (`direct-tcpip`) → un servidor eco que hace de app de desarrollo en el servidor.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjPortForwardingIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService
    private lateinit var echo: ServerSocket
    private val pool = Executors.newCachedThreadPool()

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(
            Files.createDirectories(dir.resolve("server")),
            password = PASSWORD,
            allowTcpForwarding = true,
        )
        service = SshjConnector().service(
            testServer(server.port),
            SSHCredentials.Password(PASSWORD),
            InMemoryTrustStore(),
        ) as SshjSSHService
        echo = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        thread(isDaemon = true, name = "eco") {
            while (!echo.isClosed) {
                val client = try { echo.accept() } catch (_: IOException) { break }
                pool.execute { client.use { it.getInputStream().copyTo(it.getOutputStream()) } }
            }
        }
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        echo.close()
        pool.shutdownNow()
        server.close()
    }

    @Test
    fun `el tunel lleva bytes en paralelo y archivos grandes, y se cierra`(): Unit = runBlocking {
        val forward = service.startPortForward(echo.localPort, "localhost", preferredLocalPort = 0)
        assertTrue(forward.localPort > 0)
        assertEquals("http://localhost:${forward.localPort}", forward.localUrl)
        assertEquals(listOf(forward), service.activePortForwards())

        // 8 conexiones en paralelo (cada una, su canal direct-tcpip).
        val replies = (1..8).map { n ->
            async(Dispatchers.IO) { roundTrip(forward.localPort, "hola $n".toByteArray()) }
        }.awaitAll()
        assertEquals((1..8).map { "hola $it" }, replies.map { String(it) })

        // 3 MB aleatorios: contrapresión en ambos sentidos.
        val big = Random(7).nextBytes(3 * 1024 * 1024)
        assertContentEquals(big, withContext(Dispatchers.IO) { roundTrip(forward.localPort, big) })

        service.stopPortForward(forward.id)
        assertEquals(emptyList(), service.activePortForwards())
        assertFailsWith<IOException> {
            withContext(Dispatchers.IO) { Socket(InetAddress.getLoopbackAddress(), forward.localPort).close() }
        }
    }

    @Test
    fun `usa el mismo puerto local si esta libre y otro si esta ocupado`(): Unit = runBlocking {
        val busy = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        busy.use {
            val forward = service.startPortForward(echo.localPort, "localhost", preferredLocalPort = busy.localPort)
            try {
                assertTrue(forward.localPort != busy.localPort)
                assertEquals("eco", String(withContext(Dispatchers.IO) { roundTrip(forward.localPort, "eco".toByteArray()) }))
                assertFailsWith<PortForwardException> {
                    service.startPortForward(echo.localPort, "localhost", preferredLocalPort = 0)
                }
            } finally {
                service.stopPortForward(forward.id)
            }
        }
    }

    @Test
    fun `un puerto sin servicio cierra la conexion sin colgarse`(): Unit = runBlocking {
        val closedPort = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val forward = service.startPortForward(closedPort, "localhost", preferredLocalPort = 0)
        try {
            // Cerrada sin colgarse: EOF (-1) o RST (sshj aborta el socket); nunca el timeout.
            val closed = withContext(Dispatchers.IO) {
                Socket(InetAddress.getLoopbackAddress(), forward.localPort).use { socket ->
                    socket.soTimeout = 10_000
                    try {
                        socket.getOutputStream().write("x".toByteArray())
                        socket.getInputStream().read() == -1
                    } catch (_: java.net.SocketTimeoutException) {
                        false
                    } catch (_: java.net.SocketException) {
                        true
                    }
                }
            }
            assertTrue(closed)
        } finally {
            service.stopPortForward(forward.id)
        }
    }

    @Test
    fun `puertos invalidos`(): Unit = runBlocking {
        assertFailsWith<PortForwardException> { service.startPortForward(0, "localhost", 0) }
        assertFailsWith<PortForwardException> { service.startPortForward(70_000, "localhost", 0) }
    }

    /** Envía [data], cierra la escritura y lee todo lo que vuelve. */
    private fun roundTrip(port: Int, data: ByteArray): ByteArray =
        Socket(InetAddress.getLoopbackAddress(), port).use { socket ->
            socket.soTimeout = 30_000
            val writer = thread { socket.getOutputStream().write(data); socket.shutdownOutput() }
            val reply = socket.getInputStream().readBytes()
            writer.join()
            reply
        }

    private companion object {
        const val PASSWORD = "argos-test"
    }
}
