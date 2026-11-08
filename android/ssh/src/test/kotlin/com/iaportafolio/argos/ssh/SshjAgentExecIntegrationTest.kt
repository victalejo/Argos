package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.agent.AgentExecCommands
import com.iaportafolio.argos.core.agent.AgentExecException
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import com.iaportafolio.argos.ssh.testing.FakeClaude
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createDirectories
import kotlin.io.path.deleteIfExists
import kotlin.io.path.writeText
import kotlin.test.assertContains
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** `runAgentExec` y `claudeAuthStatus` de punta a punta contra el sshd embebido (MINA). */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjAgentExecIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(dir.resolve("server")), password = AGENT_TEST_PASSWORD)
        service = agentService(server)
    }

    @AfterEach
    fun clean() {
        server.killAgentProcesses()
        FakeClaude.uninstall(server.home)
        server.home.resolve(FakeClaude.LOGGED_OUT_MARKER).deleteIfExists()
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        server.close()
    }

    // MARK: Canal

    @Test
    fun `solo stdout llega a output, sin PTY y bajo sh`() = execTest {
        val output = TerminalOutput()
        service.runAgentExec("echo \"\$0\"; echo error >&2; [ -t 0 ] && echo con-pty || echo sin-pty", emptyFlowOpen(), output::append)

        assertEquals("sh\nsin-pty\n", output.text())
    }

    @Test
    fun `el comando se envuelve como posixShell de Swift`() {
        assertEquals("sh -c 'echo '\\''hola'\\'' \$HOME'", posixShell("echo 'hola' \$HOME"))
    }

    @Test
    fun `el canal es 8-bit safe en ambos sentidos`() = execTest {
        val bytes = ByteArray(256) { it.toByte() } + "ñ€😀\r\n\u0003".toByteArray()
        val output = TerminalOutput()
        val stdin = Channel<ByteArray>(Channel.UNLIMITED)
        val run = launch { service.runAgentExec("cat", stdin.receiveAsFlow(), output::append) }

        stdin.send(bytes)
        eventually("vuelven todos los bytes") { output.bytes().size >= bytes.size }

        assertContentEquals(bytes, output.bytes())
        run.cancelAndJoin()
    }

    @Test
    fun `termina con el EOF del proceso aunque stdin siga abierto`() = execTest {
        val output = TerminalOutput()
        service.runAgentExec("echo fin", emptyFlowOpen(), output::append)

        assertEquals("fin\n", output.text())
    }

    @Test
    fun `termina cuando stdin se completa aunque el proceso siga vivo`() = execTest {
        val stdin = Channel<ByteArray>(Channel.UNLIMITED)
        val output = TerminalOutput()
        val run = launch {
            service.runAgentExec("echo listo; cat > /dev/null", stdin.receiveAsFlow(), output::append)
        }
        eventually("el proceso está en marcha") { output.text() == "listo\n" }

        stdin.close()
        run.join()

        assertFalse(run.isCancelled)
        eventually("se cierra la conexión dedicada") { server.activeConnections <= 1 }
    }

    @Test
    fun `la salida se entrega en orden y con textos largos`() = execTest {
        val output = TerminalOutput()
        service.runAgentExec("i=0; while [ \$i -lt 20000 ]; do echo linea-\$i; i=\$((i+1)); done", emptyFlowOpen(), output::append)

        val lines = output.text().lines().filter { it.isNotEmpty() }
        assertEquals((0 until 20000).map { "linea-$it" }, lines)
    }

    // MARK: Errores

    @Test
    fun `si falla con stderr lanza AgentExecException con el detalle`() = execTest {
        val output = TerminalOutput()
        val error = assertFailsWith<AgentExecException> {
            service.runAgentExec("echo parcial; echo 'not logged in' >&2; exit 3", emptyFlowOpen(), output::append)
        }

        assertEquals("not logged in", error.detail)
        assertContains(error.message.orEmpty(), "El agente de Claude se cerró")
        assertEquals("parcial\n", output.text())
    }

    @Test
    fun `del stderr solo se conservan los últimos 600 caracteres`() = execTest {
        val text = "é".repeat(700) + "fin"
        server.home.resolve("largo.txt").writeText(text)
        val error = assertFailsWith<AgentExecException> {
            service.runAgentExec("cat largo.txt >&2; exit 1", emptyFlowOpen(), TerminalOutput()::append)
        }

        assertEquals(text.takeLast(600), error.detail)
    }

    @Test
    fun `si falla sin stderr lanza CommandFailed con el código`() = execTest {
        val error = assertFailsWith<SSHServiceError.CommandFailed> {
            service.runAgentExec("exit 7", emptyFlowOpen(), TerminalOutput()::append)
        }

        assertEquals(7, error.exitCode)
    }

    @Test
    fun `stderr con salida correcta no es un error`() = execTest {
        service.runAgentExec("echo aviso >&2", emptyFlowOpen(), TerminalOutput()::append)
    }

    @Test
    fun `una excepción de output cierra el canal y se propaga`() = execTest {
        val baseline = server.activeConnections
        val error = assertFailsWith<IllegalStateException> {
            service.runAgentExec("echo a; cat", emptyFlowOpen()) { error("fallo del consumidor") }
        }

        assertEquals("fallo del consumidor", error.message)
        eventually("se cierra la conexión dedicada") { server.activeConnections <= baseline }
    }

    @Test
    fun `una host key distinta aborta también en la conexión dedicada`() = execTest {
        val distrusted = SshjConnector().service(
            testServer(server.port),
            SSHCredentials.Password(AGENT_TEST_PASSWORD),
            InMemoryTrustStore(mapOf("127.0.0.1:${server.port}" to "SHA256:otra")),
        ) as SshjSSHService

        assertFailsWith<HostKeyMismatchException> {
            distrusted.runAgentExec("echo no", emptyFlowOpen(), TerminalOutput()::append)
        }
    }

    @Test
    fun `unas credenciales erróneas fallan con AuthenticationFailed`() = execTest {
        val rejected = SshjConnector().service(
            testServer(server.port),
            SSHCredentials.Password("mala"),
            InMemoryTrustStore(),
        ) as SshjSSHService

        assertFailsWith<SshConnectionException.AuthenticationFailed> {
            rejected.runAgentExec("echo no", emptyFlowOpen(), TerminalOutput()::append)
        }
    }

    @Test
    fun `si la red cae lanza SshAgentChannelException y no deja hilos`() = execTest {
        val proxy = TcpProxy(server.port)
        val proxied = agentService(server, proxy.port)
        val output = TerminalOutput()
        val run = async(Dispatchers.Default) {
            runCatching { proxied.runAgentExec("echo listo; cat", emptyFlowOpen(), output::append) }
        }
        eventually("el comando está en marcha") { output.text() == "listo\n" }

        proxy.close()

        assertFailsWith<SshAgentChannelException> { run.await().getOrThrow() }
        eventually("no quedan lectores: ${agentExecThreads()}") { agentExecThreads().isEmpty() }
        proxied.disconnect()
    }

    @Test
    fun `disconnect del servicio cierra también las conexiones dedicadas`() = execTest {
        val own = agentService(server)
        val output = TerminalOutput()
        val run = async(Dispatchers.Default) {
            runCatching { own.runAgentExec("echo listo; cat", emptyFlowOpen(), output::append) }
        }
        eventually("el comando está en marcha") { output.text() == "listo\n" }

        own.disconnect()

        assertFailsWith<SshAgentChannelException> { run.await().getOrThrow() }
    }

    // MARK: Conexión dedicada y cancelación

    @Test
    fun `cada llamada usa su propia conexión, que se cierra siempre`() = execTest {
        service.testConnection()
        val baseline = server.activeConnections
        val output = TerminalOutput()
        val run = launch { service.runAgentExec("echo listo; cat", emptyFlowOpen(), output::append) }
        eventually("el comando está en marcha") { output.text() == "listo\n" }
        assertEquals(baseline + 1, server.activeConnections)

        run.cancelAndJoin()
        eventually("se cierra al cancelar") { server.activeConnections == baseline }

        service.runAgentExec("echo a", emptyFlowOpen(), TerminalOutput()::append)
        eventually("se cierra al terminar") { server.activeConnections == baseline }

        runCatching { service.runAgentExec("exit 1", emptyFlowOpen(), TerminalOutput()::append) }
        eventually("se cierra al fallar") { server.activeConnections == baseline }
    }

    @Test
    fun `no agota MaxSessions con más canales largos que el límite`() = execTest {
        val count = EmbeddedSshServer.MAX_CHANNELS_PER_CONNECTION + 3
        val outputs = List(count) { TerminalOutput() }
        val runs = outputs.map { output ->
            launch(Dispatchers.Default) { service.runAgentExec("echo listo; cat", emptyFlowOpen(), output::append) }
        }
        eventually("todos están en marcha", timeoutMillis = 30_000) { outputs.all { it.text() == "listo\n" } }

        // La conexión compartida sigue disponible para los comandos cortos.
        assertEquals("hola\n", service.runAgentScript("echo hola"))

        runs.forEach { it.cancelAndJoin() }
    }

    @Test
    fun `el límite de canales del servidor de pruebas existe de verdad`() = execTest {
        val own = agentService(server)
        val attempts = List(EmbeddedSshServer.MAX_CHANNELS_PER_CONNECTION + 3) {
            async(Dispatchers.Default) { runCatching { own.attachCommand("cat", 80, 24, emptyFlow(), TerminalOutput()::append) } }
        }

        eventually("algún canal se rechaza") { attempts.any { it.isCompleted } }

        val rejected = attempts.filter { it.isCompleted }.map { it.await().exceptionOrNull() }
        // MINA corta la conexión al pasarse del límite; OpenSSH solo rechaza el canal.
        assertTrue(rejected.any { it is SshTerminalException }, "Rechazos: $rejected")
        attempts.forEach { it.cancelAndJoin() }
        own.disconnect()
    }

    @Test
    fun `cancelar interrumpe lectores y escritor sin dejar hilos ni procesos`() = execTest {
        val output = TerminalOutput()
        val threadsBefore = sshjThreads().size
        val run = launch { service.runAgentExec("echo listo; cat", emptyFlowOpen(), output::append) }
        eventually("el comando está en marcha") { output.text() == "listo\n" }
        assertTrue(agentExecThreads().isNotEmpty(), "Se esperaban lectores activos")

        run.cancelAndJoin()

        assertTrue(run.isCancelled)
        eventually("no quedan hilos del canal: ${agentExecThreads()}") { agentExecThreads().isEmpty() }
        eventually("no quedan hilos de sshj de más: ${sshjThreads()}") { sshjThreads().size <= threadsBefore }
    }

    @Test
    fun `cancelar mientras output está suspendido no se cuelga`() = execTest {
        val entered = CompletableDeferred<Unit>()
        val run = launch {
            service.runAgentExec("while :; do echo x; done", emptyFlowOpen()) {
                entered.complete(Unit)
                awaitCancellation()
            }
        }
        entered.await()

        run.cancelAndJoin()

        eventually("no quedan hilos del canal: ${agentExecThreads()}") { agentExecThreads().isEmpty() }
    }

    @Test
    fun `cancelar no mata lo que corre en el servidor por su cuenta`() = execTest {
        val pidFile = server.home.resolve("independiente.pid")
        val output = TerminalOutput()
        val script = "nohup sh -c 'echo \$\$ > independiente.pid; exec sleep 30' >/dev/null 2>&1 </dev/null & echo listo; cat"
        val run = launch { service.runAgentExec(script, emptyFlowOpen(), output::append) }
        eventually("arrancó") { output.text() == "listo\n" && Files.exists(pidFile) && Files.size(pidFile) > 0 }

        run.cancelAndJoin()

        val pid = Files.readString(pidFile).trim()
        assertTrue(server.runLocal("ps -o pid= -p $pid").isNotBlank())
        server.runLocal("kill -9 $pid")
    }

    // MARK: claude auth status

    @Test
    fun `claudeAuthStatus con claude simulado logueado`() = execTest {
        FakeClaude.install(server.home)

        val status = service.claudeAuthStatus()

        assertEquals(ClaudeAuthStatus(true, "max", "demo@argos.invalid"), status)
        assertTrue(status?.usesSubscription == true)
    }

    @Test
    fun `claudeAuthStatus con claude simulado no logueado`() = execTest {
        FakeClaude.install(server.home)
        server.home.resolve(FakeClaude.LOGGED_OUT_MARKER).writeText("")

        assertEquals(ClaudeAuthStatus(false, null, null), service.claudeAuthStatus())
    }

    @Test
    fun `claudeAuthStatus sin claude devuelve null`() = execTest {
        assumeNoSystemClaude()

        assertNull(service.locateClaude())
        assertNull(service.claudeAuthStatus())
    }

    // MARK: Aislamiento del claude real

    @Test
    fun `el servidor resuelve el simulado, nunca un claude de la máquina`() {
        val path = server.runLocal("printf %s \"\$PATH\"").split(File.pathSeparator)

        assertEquals(server.home.resolve(".local/bin").toString(), path.first())
        path.drop(1).forEach { assertFalse(Files.isExecutable(Path.of(it, "claude")), "PATH con claude: $it") }

        FakeClaude.install(server.home)
        FakeClaude.verifyResolves(server)
    }

    @Test
    fun `runAgentScript corre bajo sh aunque el shell de login sea otro`(@TempDir dir: Path) {
        assumeTrue(Files.isExecutable(Path.of(ZSH)), "Sin zsh")
        EmbeddedSshServer.start(dir.resolve("zsh").createDirectories(), password = AGENT_TEST_PASSWORD, loginShell = ZSH).use { zshServer ->
            val zshService = agentService(zshServer)
            runBlocking {
                // Con zsh sin envolver: «no matches found» por el comodín sin coincidencias.
                assertEquals("\n", zshService.runAgentScript("for d in \"\$HOME\"/nada*/; do :; done; echo"))
                assertEquals("sh\n", zshService.runAgentScript("echo \"\$0\""))
                zshService.installedCodingAgents()
                zshService.disconnect()
            }
        }
    }

    private fun assumeNoSystemClaude() {
        val found = server.runLocal(AgentExecCommands.LOCATE_CLAUDE_SCRIPT).trim()
        assumeTrue(found.isEmpty(), "Esta máquina tiene un claude en una ruta fija: $found")
    }

    /** stdin que no termina: el flujo que usa un enganche. */
    private fun emptyFlowOpen(): Flow<ByteArray> = flow { awaitCancellation() }

    private fun execTest(block: suspend CoroutineScope.() -> Unit) = runBlocking<Unit> {
        withTimeout(TEST_TIMEOUT_MILLIS) { coroutineScope { block() } }
    }

    private companion object {
        const val TEST_TIMEOUT_MILLIS = 60_000L
        const val ZSH = "/bin/zsh"
    }
}
