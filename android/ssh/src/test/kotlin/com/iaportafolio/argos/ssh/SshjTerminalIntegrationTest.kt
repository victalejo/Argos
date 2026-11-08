package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.TerminalControlEvent
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.writeText
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Terminal en vivo de punta a punta: sshj → MINA SSHD con PTY REAL (pty4j) → `tmux attach` real.
 * El tamaño se comprueba con lo que ve tmux (`list-clients`), no con lo que enviamos.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjTerminalIntegrationTest {

    private lateinit var workDir: Path
    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService

    @BeforeAll
    fun start(@TempDir dir: Path) {
        workDir = dir
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(workDir.resolve("server")), password = PASSWORD)
        service = serviceFor(server)
    }

    @AfterEach
    fun killTmux() {
        server.killTmux()
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        server.close()
    }

    @Test
    fun `adjunta a una sesión, recibe la salida inicial y las teclas llegan a tmux`() = terminalTest {
        service.createSession("marca")
        val control = controlChannel()
        val output = TerminalOutput()
        val attach = launch { service.attachTerminal("marca", 100, 30, control.consumeAsFlow(), output::append) }

        eventually("tmux tiene un cliente adjunto") { clientSizes("marca").isNotEmpty() }
        eventually("llega la salida inicial de tmux") { output.bytes().isNotEmpty() }

        control.send(keys("echo marca-\$((100+23))\r"))
        eventually("el panel muestra el resultado") { capturePane("marca").contains("marca-123") }
        eventually("la salida del PTY trae el resultado") { output.plainText().contains("marca-123") }

        attach.cancelAndJoin()
    }

    @Test
    fun `el tamaño inicial y Resize cambian el tamaño que ve tmux`() = terminalTest {
        service.createSession("tamano")
        val control = controlChannel()
        val attach = launch { service.attachTerminal("tamano", 100, 30, control.consumeAsFlow(), TerminalOutput()::append) }

        eventually("tmux ve 100x30") { clientSizes("tamano") == listOf("100x30") }
        control.send(TerminalControlEvent.Resize(cols = 132, rows = 43))
        eventually("tmux ve 132x43 tras el window-change") { clientSizes("tamano") == listOf("132x43") }

        // Tamaño transitorio de maquetación (2x1): se descarta, como en Apple.
        control.send(TerminalControlEvent.Resize(cols = 2, rows = 1))
        delay(SETTLE_MILLIS)
        assertEquals(listOf("132x43"), clientSizes("tamano"))

        attach.cancelAndJoin()
    }

    @Test
    fun `un tamaño inicial inutilizable abre el PTY a 80x24`() = terminalTest {
        service.createSession("minimo")
        val attach = launch { service.attachTerminal("minimo", 2, 1, emptyFlow(), TerminalOutput()::append) }

        eventually("tmux ve 80x24") { clientSizes("minimo") == listOf("80x24") }
        attach.cancelAndJoin()
    }

    @Test
    fun `cancelar desengancha sin matar la sesión ni dejar lectores colgados`() = terminalTest {
        service.createSession("viva")
        val attach = launch { service.attachTerminal("viva", 100, 30, emptyFlow(), TerminalOutput()::append) }
        eventually("tmux tiene un cliente adjunto") { clientSizes("viva").isNotEmpty() }

        attach.cancelAndJoin()

        assertTrue(attach.isCancelled)
        eventually("tmux desengancha al cliente") { clientSizes("viva").isEmpty() }
        assertEquals(listOf("viva"), service.listSessions().map { it.name })
        eventually("no quedan hilos dentro del bombeo: ${terminalReaderThreads()}") { terminalReaderThreads().isEmpty() }
    }

    @Test
    fun `tmux detach desde dentro hace que attachTerminal retorne`() = terminalTest {
        service.createSession("salida")
        val control = controlChannel()
        val attach = async { service.attachTerminal("salida", 100, 30, control.consumeAsFlow(), TerminalOutput()::append) }
        eventually("tmux tiene un cliente adjunto") { clientSizes("salida").isNotEmpty() }

        control.send(keys("tmux detach-client\r"))
        attach.await()

        assertFalse(attach.isCancelled)
        assertEquals(listOf("salida"), service.listSessions().map { it.name })
    }

    @Test
    fun `matar la sesión hace que attachTerminal retorne con normalidad`() = terminalTest {
        service.createSession("efimera")
        val attach = async { service.attachTerminal("efimera", 100, 30, emptyFlow(), TerminalOutput()::append) }
        eventually("tmux tiene un cliente adjunto") { clientSizes("efimera").isNotEmpty() }

        service.killSession("efimera")
        attach.await()
    }

    @Test
    fun `dos terminales simultáneos y la gestión comparten la conexión en paralelo`() = terminalTest {
        service.createSession("uno")
        service.createSession("dos")
        val controlUno = controlChannel()
        val controlDos = controlChannel()
        val uno = launch(Dispatchers.Default) {
            service.attachTerminal("uno", 90, 25, controlUno.consumeAsFlow(), TerminalOutput()::append)
        }
        val dos = launch(Dispatchers.Default) {
            service.attachTerminal("dos", 110, 35, controlDos.consumeAsFlow(), TerminalOutput()::append)
        }

        eventually("ambas sesiones tienen cliente") {
            clientSizes("uno") == listOf("90x25") && clientSizes("dos") == listOf("110x35")
        }
        // Gestión por la MISMA conexión mientras los dos canales largos siguen abiertos.
        val listings = (1..5).map { async(Dispatchers.Default) { service.listSessions() } }.map { it.await() }
        listings.forEach { sessions ->
            assertEquals(setOf("uno", "dos"), sessions.map { it.name }.toSet())
            assertTrue(sessions.all { it.isAttached })
        }

        controlUno.send(keys("echo uno-\$((1+1))\r"))
        controlDos.send(keys("echo dos-\$((2+2))\r"))
        eventually("cada teclado va a su sesión") {
            capturePane("uno").contains("uno-2") && capturePane("dos").contains("dos-4")
        }
        assertFalse(capturePane("uno").contains("dos-4"))

        uno.cancelAndJoin()
        dos.cancelAndJoin()
    }

    @Test
    fun `attachCommand ejecuta el comando en el PTY y retorna al terminar`() = terminalTest {
        val output = TerminalOutput()
        service.attachCommand("echo hola-\$((40+2)) term=\$TERM", 80, 24, emptyFlow(), output::append)

        assertContains(output.plainText(), "hola-42 term=xterm-256color")
    }

    @Test
    fun `los bytes UTF-8 partidos entre bloques llegan intactos y sin decodificar`() = terminalTest {
        val text = "ñandú€😀".repeat(UTF8_REPEAT)
        server.home.resolve("utf8.txt").writeText(text)
        val output = TerminalOutput()

        service.attachCommand("cat utf8.txt", 80, 24, emptyFlow(), output::append)

        assertTrue(output.chunks.size > 1, "Se esperaban varios bloques")
        assertTrue(output.chunks.all { it.size <= MAX_CHUNK }, "Bloque mayor que el máximo")
        assertContains(output.text(), text)
        // Prueba de que el caso se ejercita: algún bloque termina en un byte inicial multibyte.
        assertTrue(output.chunks.any { (it.last().toInt() and UTF8_LEAD_MASK) == UTF8_LEAD_MASK })
    }

    @Test
    fun `si la conexión cae con el terminal abierto lanza ConnectionLost`() = terminalTest {
        // Corte de red simulado: un proxy TCP que se cierra de golpe (sin cierre ordenado del canal).
        val proxy = TcpProxy(server.port)
        val proxied = SshjConnector().service(
            testServer(proxy.port),
            SSHCredentials.Password(PASSWORD),
            InMemoryTrustStore(),
        ) as SshjSSHService
        val output = TerminalOutput()
        val attach = async(Dispatchers.Default) {
            runCatching { proxied.attachCommand("sh -c 'echo listo-\$((1+1)); cat'", 80, 24, emptyFlow(), output::append) }
        }
        eventually("el comando está en marcha") { output.plainText().contains("listo-2") }

        proxy.close()

        val error = assertFailsWith<SshTerminalException.ConnectionLost> { attach.await().getOrThrow() }
        assertContains(error.message.orEmpty(), "Se perdió la conexión")
        proxied.disconnect()
    }

    @Test
    fun `adjuntar a una sesión inexistente retorna cuando tmux sale`() = terminalTest {
        service.createSession("otra")
        val output = TerminalOutput()
        service.attachTerminal("no-existe", 80, 24, emptyFlow(), output::append)

        assertContains(output.plainText(), "can't find session")
    }

    // MARK: Utilidades

    private fun serviceFor(target: EmbeddedSshServer): SshjSSHService = SshjConnector().service(
        testServer(target.port),
        SSHCredentials.Password(PASSWORD),
        InMemoryTrustStore(),
    ) as SshjSSHService

    /** Tamaños `colsxfilas` de los clientes adjuntos a [session], según tmux. */
    private fun clientSizes(session: String): List<String> = server
        .runLocal("tmux list-clients -t ${ShellQuoting.singleQuoted(session)} -F '#{client_width}x#{client_height}' 2>/dev/null")
        .lines()
        .filter { it.isNotBlank() }

    private fun capturePane(session: String): String =
        server.runLocal("tmux capture-pane -p -t ${ShellQuoting.singleQuoted(session)}")

    private fun terminalTest(block: suspend CoroutineScope.() -> Unit) = runBlocking<Unit> {
        withTimeout(TEST_TIMEOUT_MILLIS) { coroutineScope { block() } }
    }

    private companion object {
        const val PASSWORD = "argos-test"
        const val TEST_TIMEOUT_MILLIS = 60_000L
        const val SETTLE_MILLIS = 500L
        const val UTF8_REPEAT = 20_000
        const val MAX_CHUNK = 16 * 1024
        const val UTF8_LEAD_MASK = 0xC0
    }
}
