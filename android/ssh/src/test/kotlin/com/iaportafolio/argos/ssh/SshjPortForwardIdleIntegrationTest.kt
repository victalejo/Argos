package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.ports.PortForwardDevice
import com.iaportafolio.argos.core.ports.PortForwardIdlePolicy
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.io.path.exists
import kotlin.io.path.isExecutable
import kotlin.io.path.readText
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Cierre por inactividad y archivos de la skill de Claude, de punta a punta: sshj → MINA SSHD
 * (`/bin/sh`, HOME aislado). El reloj del vigilante es falso para no esperar minutos.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjPortForwardIdleIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var connection: SshjConnection
    private lateinit var echo: ServerSocket
    private var now = 1_000_000_000L

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(
            Files.createDirectories(dir.resolve("server")),
            password = PASSWORD,
            allowTcpForwarding = true,
        )
        connection = SshjConnection(
            testServer(server.port),
            SSHCredentials.Password(PASSWORD),
            InMemoryTrustStore(),
            SshjConnector.Settings(),
        )
        echo = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        thread(isDaemon = true, name = "eco") {
            while (!echo.isClosed) {
                val client = runCatching { echo.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { client.use { it.getInputStream().copyTo(it.getOutputStream()) } }
            }
        }
        PortForwardDevice.id = "TEST-DEV"
        PortForwardDevice.name = "Pixel de pruebas"
    }

    @AfterAll
    fun stop() {
        runBlocking { connection.disconnect() }
        echo.close()
        server.close()
    }

    @Test
    fun `cierra el tunel sin uso, nunca con una conexion abierta, y publica para Claude`(): Unit = runBlocking {
        PortForwardIdlePolicy.limitMinutes = 5
        val ports = SshjPortForwarding(connection, watchIntervalMillis = 3_600_000L, clock = { now })
        ports.listeningPorts()   // instala argos-ports y la skill

        val script = server.home.resolve(".claude/skills/argos-puertos/argos-ports")
        val skill = server.home.resolve(".claude/skills/argos-puertos/SKILL.md")
        assertTrue(script.isExecutable())
        assertTrue(skill.readText().startsWith("---\nname: argos-puertos\n"))

        val forward = ports.startPortForward(echo.localPort, "localhost", preferredLocalPort = 0)
        val file = server.home.resolve(".config/argos/forwards/TEST-DEV.tsv")
        assertTrue(file.exists())
        val listing = runScript(script)
        assertTrue("- Pixel de pruebas" in listing, listing)
        assertTrue("puerto ${echo.localPort} del servidor -> http://localhost:${forward.localPort}" in listing, listing)

        // Una conexión abierta mantiene vivo el túnel aunque pase el límite.
        val open = withContext(Dispatchers.IO) { Socket(InetAddress.getLoopbackAddress(), forward.localPort) }
        waitUntil { ports.activeConnections(forward.id) == 1 }
        now += 10 * 60_000L
        assertTrue(ports.watchOnce())
        assertEquals(listOf(forward.id), ports.activePortForwards().map { it.id })

        // Al cerrarla, cuenta desde ese momento: a los 4 min sigue, a los 5 se cierra.
        withContext(Dispatchers.IO) { open.close() }
        waitUntil { ports.activeConnections(forward.id) == 0 }
        now += 4 * 60_000L
        assertTrue(ports.watchOnce())
        now += 2 * 60_000L
        assertFalse(ports.watchOnce())
        assertTrue(ports.activePortForwards().isEmpty())
        assertFalse(file.exists(), "el archivo del dispositivo debe borrarse sin túneles")
        assertTrue("(ninguno" in runScript(script))
    }

    @Test
    fun `con el limite en Nunca no se cierra`(): Unit = runBlocking {
        PortForwardIdlePolicy.limitMinutes = 0
        val ports = SshjPortForwarding(connection, watchIntervalMillis = 3_600_000L, clock = { now })
        val forward = ports.startPortForward(echo.localPort, "localhost", preferredLocalPort = 0)
        try {
            now += 24 * 60 * 60_000L
            assertTrue(ports.watchOnce())
            assertEquals(1, ports.activePortForwards().size)
        } finally {
            ports.stopPortForward(forward.id)
            PortForwardIdlePolicy.limitMinutes = PortForwardIdlePolicy.DEFAULT_MINUTES
        }
    }

    private fun runScript(script: Path): String {
        val process = ProcessBuilder("/bin/sh", script.toString())
            .apply { environment()["HOME"] = server.home.toString() }
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText()
        process.waitFor(10, TimeUnit.SECONDS)
        return output
    }

    private suspend fun waitUntil(condition: suspend () -> Boolean) {
        repeat(100) {
            if (condition()) return
            delay(50)
        }
        error("la condición no se cumplió a tiempo")
    }

    private companion object {
        const val PASSWORD = "argos-test"
    }
}
