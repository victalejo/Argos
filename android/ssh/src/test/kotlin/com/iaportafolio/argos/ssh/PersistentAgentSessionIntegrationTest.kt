package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.agent.AgentExecCommands
import com.iaportafolio.argos.core.agent.AgentExecException
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.AgentPermissionDecision
import com.iaportafolio.argos.core.agent.AgentStatus
import com.iaportafolio.argos.core.agent.AgentTranscriptItem.Kind
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.PersistentAgentError
import com.iaportafolio.argos.core.agent.PersistentAgentException
import com.iaportafolio.argos.core.agent.PersistentAgentInfo
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.core.agent.PersistentAgentSession
import com.iaportafolio.argos.core.agent.PersistentAgentSessionState
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import com.iaportafolio.argos.ssh.testing.FakeClaude
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.io.path.createDirectories
import kotlin.io.path.exists
import kotlin.io.path.readText
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `PersistentAgentSession` de punta a punta: sshj → MINA SSHD → los scripts reales del servidor
 * (FIFO, log, `tail`, `ps`) → el `claude` SIMULADO. Ningún test puede lanzar el `claude` real: el
 * PATH del servidor no lo resuelve y [setUp] verifica lo que resuelve el script de la app.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class PersistentAgentSessionIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService
    private lateinit var project: Path
    private lateinit var scope: CoroutineScope

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(dir.resolve("server")), password = AGENT_TEST_PASSWORD)
        project = server.home.resolve("proyectos/demo").createDirectories()
    }

    @BeforeEach
    fun setUp() {
        FakeClaude.install(server.home, testMode = true)
        FakeClaude.verifyResolves(server)
        service = agentService(server)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    /** Nada huérfano: cada test deja la máquina sin procesos del simulado ni `tail`. */
    @AfterEach
    fun tearDown() {
        scope.cancel()
        runBlocking { service.disconnect() }
        server.killAgentProcesses()
        runBlocking { eventually("no queda ningún proceso: ${server.agentProcesses()}") { server.agentProcesses().isEmpty() } }
        server.home.resolve(".config/argos/agents").toFile().deleteRecursively()
        server.home.resolve(FakeClaude.TEST_DIRECTORY).toFile().deleteRecursively()
        project.toFile().listFiles()?.forEach { it.deleteRecursively() }
    }

    @AfterAll
    fun stop() {
        server.close()
    }

    // MARK: launch + token

    @Test
    fun `launch lanza claude con los flags persistentes y aparece vivo en la lista`() = agentTest {
        val session = launchAgent(title = "Mi agente")

        val args = recorded(session, "args")
        listOf(
            "-p", "--input-format stream-json", "--output-format stream-json", "--verbose",
            "--permission-prompt-tool stdio", "--replay-user-messages", "--permission-mode default",
            "--session-id ${session.id}",
        ).forEach { assertContains(args, it) }
        val info = onlyAgent()
        assertEquals(session.id, info.id)
        assertTrue(info.isAlive)
        assertEquals("Mi agente", info.meta.title)
        assertEquals(project.toString(), info.meta.workingDirectory)
        assertTrue(session.state.value.isAlive)
        assertFalse(session.state.value.isAttached)
    }

    @Test
    fun `el token llega por stdin y no aparece en ps, ni en comandos, ni en disco`() = agentTest {
        val token = "tok-'\"\$(touch>pwn)-${System.nanoTime()}"
        val seenInPs = CopyOnWriteArrayList<String>()
        val sampler = launch(Dispatchers.IO) {
            while (isActive) {
                val listing = ProcessBuilder("ps", "axww", "-o", "args=").redirectErrorStream(true).start()
                    .inputStream.bufferedReader().readText()
                if (TOKEN_NEEDLE in listing) seenInPs += listing
                delay(5)
            }
        }
        val exec = RecordingAgentExec(service)

        val session = PersistentAgentSession.launch(
            service, exec, project.toString(), "t", token.replace("tok-", "tok-$TOKEN_NEEDLE-"), scope,
        )

        eventually("el simulado recibió el token") { recordedOrNull(session, "token")?.isNotEmpty() == true }
        sampler.cancelAndJoin()
        val received = recorded(session, "token")
        assertEquals(token.replace("tok-", "tok-$TOKEN_NEEDLE-"), received)
        assertEquals("", recorded(session, "leaked"), "ARGOS_OAUTH no debe llegar a claude")
        assertTrue(seenInPs.isEmpty(), "Token visible en ps: ${seenInPs.firstOrNull()}")
        assertFalse(exec.commands.any { TOKEN_NEEDLE in it }, "Token en la línea de comandos")
        assertFalse(recorded(session, "args").contains(TOKEN_NEEDLE))
        val agentDir = agentDirectory(session)
        agentDir.toFile().walkTopDown().filter { it.isFile }.forEach {
            assertFalse(TOKEN_NEEDLE in it.readText(), "Token en ${it.name}")
        }
        assertFalse(server.home.resolve("pwn").exists(), "El token se interpretó en el shell")
        assertFalse(project.resolve("pwn").exists(), "El token se interpretó en el shell")
    }

    @Test
    fun `sin token claude no recibe CLAUDE_CODE_OAUTH_TOKEN`() = agentTest {
        val session = launchAgent(token = null)

        eventually("arrancó") { recordedOrNull(session, "token") != null }
        assertEquals("", recorded(session, "token"))
    }

    @Test
    fun `claude no instalado da CLAUDE_MISSING al lanzar y lastError al reanudar`() = agentTest {
        val session = launchAgent()
        session.stop()
        FakeClaude.uninstall(server.home)
        assumeNoSystemClaude()

        val error = assertFailsWith<PersistentAgentException> { launchAgent() }
        assertEquals(PersistentAgentError.CLAUDE_MISSING, error.error)

        session.resume(null)
        assertEquals(PersistentAgentError.CLAUDE_MISSING.message, session.state.value.lastError)
        assertFalse(session.state.value.isAlive)
    }

    @Test
    fun `si otro dispositivo tiene el cerrojo responde BUSY`() = agentTest {
        val session = launchAgent()
        session.stop()
        val lock = server.home.resolve(".config/argos/agents/.${session.id}.lock").createDirectories()

        session.resume(null)

        assertEquals(PersistentAgentError.BUSY.message, session.state.value.lastError)
        assertFalse(session.state.value.isAlive)
        Files.delete(lock)
    }

    // MARK: Conversación

    @Test
    fun `attach, send y permiso aprobado de punta a punta`() = agentTest {
        val session = launchAgent()
        session.attach()
        eventually("enganchado") { session.state.value.isAttached }

        session.send("  crea las notas\n")

        val permission = awaitPermission(session)
        assertEquals("Write", permission.toolName)
        assertEquals("Write", permission.displayName)
        val state = session.state.value
        assertEquals(session.id, state.conversation.sessionID)
        assertEquals(AgentStatus.Working, state.conversation.status)
        assertEquals("crea las notas", state.conversation.items.filter { it.kind is Kind.UserText }.map { (it.kind as Kind.UserText).text }.single())
        assertTrue(state.conversation.items.any { it.kind is Kind.Thinking })
        assertTrue(state.conversation.items.any { (it.kind as? Kind.ToolUse)?.name == "Write" })
        assertTrue(state.receivedBytes > 0)
        assertNull(state.lastError)
        assertFalse(project.resolve(FIRST_NOTES).exists())

        session.allowPendingPermission()

        awaitIdle(session)
        val done = session.state.value.conversation
        assertNull(done.pendingPermission)
        assertTrue(project.resolve(FIRST_NOTES).exists())
        val toolResult = done.items.mapNotNull { it.kind as? Kind.ToolResult }.single()
        assertFalse(toolResult.isError)
        assertContains(toolResult.text, "File created successfully")
        assertEquals("He creado `$FIRST_NOTES`.", assistantTexts(session).last())
        val result = done.items.mapNotNull { it.kind as? Kind.Result }.single().result
        assertFalse(result.isError)
        assertEquals(0.0, result.totalCostUSD)
        // Lo que llegó a claude es el control_response del protocolo, con el input sin cambios.
        val response = recorded(session, "stdin").lines().first { "control_response" in it }
        assertContains(response, "\"request_id\":\"${permission.id}\"")
        assertContains(response, "\"behavior\":\"allow\"")
        assertContains(response, "\"updatedInput\":{")
        assertContains(response, FIRST_NOTES)
    }

    @Test
    fun `permiso denegado no crea el archivo y claude lo refleja`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("crea las notas")
        awaitPermission(session)

        session.denyPendingPermission()

        awaitIdle(session)
        assertFalse(project.resolve(FIRST_NOTES).exists())
        val toolResult = session.state.value.conversation.items.mapNotNull { it.kind as? Kind.ToolResult }.single()
        assertTrue(toolResult.isError)
        assertEquals(AgentPermissionDecision.USER_DENIED_MESSAGE, toolResult.text)
        assertContains(assistantTexts(session).last(), "**no** he creado el archivo")
    }

    @Test
    fun `varias vueltas alternan permiso y markdown y recuerdan lo anterior`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("uno")
        awaitPermission(session)
        session.allowPendingPermission()
        awaitResults(session, 1)

        session.send("dos")
        awaitResults(session, 2)

        assertContains(assistantTexts(session).last(), "**ya están**")
        assertContains(assistantTexts(session).last(), "| 2 | hecho |")
        assertNull(session.state.value.conversation.pendingPermission)
        assertEquals(AgentStatus.Idle, session.state.value.conversation.status)

        session.send("tres")
        awaitPermission(session)
        session.denyPendingPermission()
        awaitResults(session, 3)
        session.send("cuatro")
        awaitResults(session, 4)
        assertContains(assistantTexts(session).last(), "**no** se creó")
    }

    @Test
    fun `el texto del usuario viaja intacto y nunca se interpreta en el shell`() = agentTest {
        val session = launchAgent()
        session.attach()
        val tricky = "comillas \" ' \\ \$(touch>pwn) `touch pwn` ñ€😀\nsegunda línea \t fin"

        session.send(tricky)

        awaitPermission(session)
        assertEquals(tricky, session.state.value.conversation.items.firstNotNullOf { it.kind as? Kind.UserText }.text)
        assertFalse(project.resolve("pwn").exists())
        assertFalse(server.home.resolve("pwn").exists())
    }

    @Test
    fun `enviar texto vacío no hace nada`() = agentTest {
        val session = launchAgent()
        session.attach()

        session.send(" \n\t ")

        delay(SETTLE_MILLIS)
        assertEquals(emptyList(), session.state.value.conversation.items)
        assertEquals(AgentStatus.Idle, session.state.value.conversation.status)
        assertNull(recordedOrNull(session, "stdin"))
    }

    @Test
    fun `un turno que acaba antes de que send vuelva no se queda en trabajando`() = agentTest {
        var waitForResults = 0
        lateinit var session: PersistentAgentSession
        val slowWriter = object : SSHServicing by service {
            // El script de envío tarda en volver: el log trae el resultado antes.
            override suspend fun runAgentScript(command: String): String {
                val output = service.runAgentScript(command)
                if (waitForResults > 0) awaitResults(session, waitForResults)
                return output
            }
        }
        session = PersistentAgentSession.launch(slowWriter, service, project.toString(), "t", null, scope)
        session.attach()
        session.send("impar")
        awaitPermission(session)
        session.allowPendingPermission()
        awaitResults(session, 1)

        waitForResults = 2
        session.send("par")
        waitForResults = 0

        assertEquals(AgentStatus.Idle, session.state.value.conversation.status)
    }

    @Test
    fun `sin eco todavía en el log, send marca trabajando`() = agentTest {
        val session = launchAgent()

        session.send("sin enganchar")

        assertEquals(AgentStatus.Working, session.state.value.conversation.status)
    }

    // MARK: Respuesta del lanzador

    @Test
    fun `manda lo que respondió el lanzador aunque el canal falle después`() = agentTest {
        val busy = assertFailsWith<PersistentAgentException> { launchWithReply("ARGOS_AGENT_BUSY\n", IOException("corte")) }
        assertEquals(PersistentAgentError.BUSY, busy.error)

        launchWithReply("12345\n", IOException("corte"))
        launchWithReply("ARGOS_AGENT_ALIVE\n", SSHServiceError.CommandFailed(1, "x"))
    }

    @Test
    fun `sin respuesta válida del lanzador da el detalle del servidor o el mensaje genérico`() = agentTest {
        val detailed = assertFailsWith<AgentExecException> { launchWithReply("", AgentExecException("mkfifo: no")) }
        assertEquals("mkfifo: no", detailed.detail)

        val generic = assertFailsWith<AgentExecException> { launchWithReply("ruido\n", IOException("corte")) }
        assertEquals("No se pudo arrancar el agente en el servidor.", generic.detail)

        val silent = assertFailsWith<AgentExecException> { launchWithReply("", null) }
        assertEquals("No se pudo arrancar el agente en el servidor.", silent.detail)
    }

    private suspend fun launchWithReply(reply: String, failure: Exception?): PersistentAgentSession {
        val exec = object : AgentExecStreaming {
            override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
                if (reply.isNotEmpty()) output(reply.toByteArray())
                failure?.let { throw it }
            }

            override suspend fun claudeAuthStatus(): ClaudeAuthStatus? = null
        }
        return PersistentAgentSession.launch(service, exec, project.toString(), "t", null, scope)
    }

    // MARK: Enganche

    @Test
    fun `detach no para al agente y volver a enganchar relee todo sin duplicar`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("uno")
        awaitPermission(session)
        session.allowPendingPermission()
        awaitResults(session, 1)
        val before = session.state.value.conversation.items

        session.detach()

        assertFalse(session.state.value.isAttached)
        assertTrue(onlyAgent().isAlive)
        eventually("sin tail en el servidor: ${server.agentProcesses()}") { tailProcesses().isEmpty() }
        // El agente sigue trabajando sin nadie enganchado.
        session.send("dos")
        eventually("claude respondió con la app desenganchada") { logText(session).count("\"type\":\"result\"") == 2 }
        assertEquals(before, session.state.value.conversation.items)

        session.attach()

        awaitResults(session, 2)
        assertEquals(before, session.state.value.conversation.items.take(before.size))
        assertEquals(listOf("uno", "dos"), userTexts(session))
        assertEquals(Files.size(agentDirectory(session).resolve("out.ndjson")), session.state.value.receivedBytes)
    }

    @Test
    fun `un permiso sigue pendiente al reengancharse y uno respondido ya no`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("uno")
        val permission = awaitPermission(session)

        session.attach()
        assertEquals(permission, awaitPermission(session))

        session.respond(permission, AgentPermissionDecision.Allow(permission.input))
        awaitResults(session, 1)
        session.attach()
        awaitResults(session, 1)

        assertNull(session.state.value.conversation.pendingPermission)
    }

    @Test
    fun `la salida tardía de una generación vieja no pisa el enganche actual`() = agentTest {
        val exec = RecordingAgentExec(service)
        val session = PersistentAgentSession.launch(service, exec, project.toString(), "t", null, scope)
        session.attach()
        session.send("uno")
        awaitPermission(session)
        val oldOutput = exec.outputs.last()

        session.attach()
        awaitPermission(session)
        val items = session.state.value.conversation.items
        val bytes = session.state.value.receivedBytes
        oldOutput("""{"type":"assistant","message":{"content":[{"type":"text","text":"viejo"}]}}""".plus("\n").toByteArray())

        assertEquals(items, session.state.value.conversation.items)
        assertEquals(bytes, session.state.value.receivedBytes)
        assertNotEquals(exec.outputs.first(), exec.outputs.last())
    }

    @Test
    fun `reenganchar deprisa muchas veces no duplica ni deja canales`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("uno")
        awaitPermission(session)
        val expected = session.state.value.conversation.items

        repeat(RAPID_REATTACH) { session.attach() }

        eventually("la conversación se reconstruye igual") { session.state.value.conversation.items == expected }
        delay(SETTLE_MILLIS)
        assertEquals(expected, session.state.value.conversation.items)
        session.detach()
        eventually("solo queda el agente: ${server.agentProcesses()}") { tailProcesses().isEmpty() }
    }

    @Test
    fun `cerrar la conexión deja al agente vivo y se puede reenganchar`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("uno")
        awaitPermission(session)
        val agentPid = pidOf(session)

        service.disconnect()

        eventually("se desengancha") { !session.state.value.isAttached }
        assertTrue(isRunning(agentPid), "El agente debe sobrevivir a la conexión")

        // La app reabre: nueva conexión, nueva sesión a partir de la lista.
        val reopened = agentService(server)
        try {
            val info = PersistentAgentSession.list(reopened).single()
            assertTrue(info.isAlive)
            val fresh = PersistentAgentSession(reopened, reopened, info, scope)
            fresh.attach()
            awaitPermission(fresh)
            fresh.allowPendingPermission()
            awaitResults(fresh, 1)
            fresh.detach()
        } finally {
            reopened.disconnect()
        }
        assertEquals(agentPid, pidOf(session))
    }

    @Test
    fun `un corte de red informa del error y al reengancharse sigue todo`() = agentTest {
        val proxy = TcpProxy(server.port)
        val proxied = agentService(server, proxy.port)
        val session = PersistentAgentSession.launch(proxied, proxied, project.toString(), "t", null, scope)
        session.attach()
        session.send("uno")
        awaitPermission(session)

        proxy.close()

        eventually("se desengancha") { !session.state.value.isAttached }
        assertContains(session.state.value.lastError.orEmpty(), "Se perdió la conexión")
        assertTrue(isRunning(pidOf(session)))
        eventually("no quedan lectores: ${agentExecThreads()}") { agentExecThreads().isEmpty() }
        proxied.disconnect()

        val fresh = PersistentAgentSession(service, service, PersistentAgentSession.list(service).single(), scope)
        fresh.attach()
        assertEquals("Write", awaitPermission(fresh).toolName)
    }

    @Test
    fun `el agente sigue trabajando con la app desconectada`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("#lento trabaja")
        eventually("empezó") { assistantTexts(session).isNotEmpty() }
        assertEquals(AgentStatus.Working, session.state.value.conversation.status)

        session.detach()
        service.disconnect()

        eventually("terminó sin nadie conectado") { logText(session).count("\"type\":\"result\"") == 1 }
        session.attach()
        awaitResults(session, 1)
        assertEquals(listOf("Empiezo, **sin prisa**.", "Sigo trabajando…", "Terminado."), assistantTexts(session))
        assertEquals(AgentStatus.Idle, session.state.value.conversation.status)
    }

    @Test
    fun `cancelar el scope desengancha sin parar al agente ni dejar hilos`() = agentTest {
        val session = launchAgent()
        session.attach()
        eventually("hay tail") { tailProcesses().isNotEmpty() }

        scope.cancel()

        eventually("se desengancha") { !session.state.value.isAttached }
        eventually("no quedan lectores: ${agentExecThreads()}") { agentExecThreads().isEmpty() }
        eventually("sin tail: ${server.agentProcesses()}") { tailProcesses().isEmpty() }
        assertTrue(onlyAgent().isAlive)
    }

    // MARK: stop / resume / muerto

    @Test
    fun `stop para el proceso y conserva la conversación`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("uno")
        awaitPermission(session)
        val pid = pidOf(session)

        session.stop()

        assertFalse(session.state.value.isAlive)
        eventually("el proceso murió") { !isRunning(pid) }
        assertFalse(onlyAgent().isAlive)
        assertTrue(agentDirectory(session).resolve("out.ndjson").exists())
        assertFalse(agentDirectory(session).resolve("pid").exists())
    }

    @Test
    fun `stop con delete borra la carpeta y desengancha`() = agentTest {
        val session = launchAgent()
        session.attach()
        eventually("hay tail") { tailProcesses().isNotEmpty() }
        val pid = pidOf(session)

        session.stop(delete = true)

        assertFalse(session.state.value.isAlive)
        assertFalse(session.state.value.isAttached)
        assertFalse(agentDirectory(session).exists())
        eventually("el proceso murió") { !isRunning(pid) }
        eventually("sin tail: ${server.agentProcesses()}") { tailProcesses().isEmpty() }
        assertEquals(emptyList(), PersistentAgentSession.list(service))
    }

    @Test
    fun `resume tras morir relanza con --resume, reconstruye y sigue`() = agentTest {
        val session = launchAgent()
        session.attach()
        session.send("uno")
        awaitPermission(session)
        session.allowPendingPermission()
        awaitResults(session, 1)
        val oldPid = pidOf(session)
        kill(oldPid)
        eventually("murió") { !isRunning(oldPid) }
        assertFalse(onlyAgent().isAlive)

        session.resume("otro-token")

        assertTrue(session.state.value.isAlive)
        assertNull(session.state.value.lastError)
        assertTrue(session.state.value.isAttached)
        awaitResults(session, 1)
        assertEquals(listOf("uno"), userTexts(session))
        assertNotEquals(oldPid, pidOf(session))
        assertContains(recorded(session, "args").lines().last { it.isNotEmpty() }, "--resume ${session.id}")
        assertEquals("otro-token", recorded(session, "token"))
        assertTrue(onlyAgent().isAlive)

        session.send("dos")
        awaitResults(session, 2)
        assertContains(assistantTexts(session).last(), "| 2 | hecho |")
    }

    @Test
    fun `el modo de permisos se guarda en meta y reanudar lo conserva`() = agentTest {
        val session = PersistentAgentSession.launch(
            service,
            service,
            project.toString(),
            "t",
            null,
            scope,
            permissionMode = ClaudeAgentCommand.PermissionMode.PLAN,
        )
        assertContains(recorded(session, "args"), "--permission-mode plan")
        assertEquals("plan", onlyAgent().meta.permissionMode)

        val pid = pidOf(session)
        kill(pid)
        eventually("murió") { !isRunning(pid) }
        session.resume(null)

        assertContains(recorded(session, "args").lines().last { it.isNotEmpty() }, "--permission-mode plan")
        assertEquals("plan", onlyAgent().meta.permissionMode)
    }

    @Test
    fun `bypassPermissions llega al CLI si el usuario no es root`() = agentTest {
        val session = PersistentAgentSession.launch(
            service,
            service,
            project.toString(),
            "t",
            null,
            scope,
            permissionMode = ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS,
        )
        assertContains(recorded(session, "args"), "--permission-mode bypassPermissions")
    }

    @Test
    fun `resume de un agente vivo no lanza otro proceso`() = agentTest {
        val session = launchAgent()
        val pid = pidOf(session)

        session.resume(null)

        assertEquals(pid, pidOf(session))
        assertNull(session.state.value.lastError)
        assertEquals(1, recorded(session, "args").lines().count { it.isNotEmpty() })
    }

    @Test
    fun `enviar a un agente muerto marca isAlive false con el mensaje de NOT_RUNNING`() = agentTest {
        val session = launchAgent()
        session.attach()
        val pid = pidOf(session)
        kill(pid)
        eventually("murió") { !isRunning(pid) }
        val statusBefore = session.state.value.conversation.status

        session.send("¿sigues ahí?")

        assertFalse(session.state.value.isAlive)
        assertEquals(PersistentAgentError.NOT_RUNNING.message, session.state.value.lastError)
        assertEquals(statusBefore, session.state.value.conversation.status)
        assertEquals(emptyList(), userTexts(session))
    }

    @Test
    fun `un pid reutilizado por otro proceso no cuenta como agente vivo`() = agentTest {
        val session = launchAgent()
        val realPid = pidOf(session)
        val foreign = server.runLocal("nohup sleep 30 >/dev/null 2>&1 </dev/null & echo \$!").trim()
        try {
            Files.writeString(agentDirectory(session).resolve("pid"), foreign)

            assertFalse(onlyAgent().isAlive)
            session.send("hola")
            assertEquals(PersistentAgentError.NOT_RUNNING.message, session.state.value.lastError)
            session.stop()
            assertTrue(isRunning(foreign), "stop no debe matar un proceso ajeno")
        } finally {
            kill(foreign)
            kill(realPid)
        }
    }

    // MARK: list

    @Test
    fun `list sin agentes da lista vacía y con varios los ordena del más nuevo al más viejo`() = agentTest {
        assertEquals(emptyList(), PersistentAgentSession.list(service))

        val older = launchAgent(title = "viejo", now = Instant.parse("2026-01-01T00:00:00Z"))
        val newer = launchAgent(title = "nuevo", now = Instant.parse("2026-06-01T00:00:00Z"))
        newer.attach()
        newer.send("hola")
        awaitPermission(newer)
        older.stop()

        val listed = PersistentAgentSession.list(service)

        assertEquals(listOf("nuevo", "viejo"), listed.map { it.meta.title })
        assertEquals(listOf(true, false), listed.map { it.isAlive })
        assertTrue(listed.first().logBytes > 0)
        assertEquals(0, listed.last().logBytes)
        assertEquals(Instant.parse("2026-06-01T00:00:00Z"), listed.first().meta.createdAt)
    }

    // MARK: Utilidades

    private suspend fun launchAgent(
        title: String = "Agente de prueba",
        token: String? = "token-de-prueba",
        now: Instant = Instant.now(),
    ): PersistentAgentSession =
        PersistentAgentSession.launch(service, service, project.toString(), title, token, scope, now)

    private suspend fun onlyAgent(): PersistentAgentInfo = PersistentAgentSession.list(service).single()

    private suspend fun awaitPermission(session: PersistentAgentSession) = run {
        eventually("llega la petición de permiso: ${describe(session)}") { session.state.value.conversation.pendingPermission != null }
        assertNotNull(session.state.value.conversation.pendingPermission)
    }

    private suspend fun awaitResults(session: PersistentAgentSession, count: Int) {
        eventually("llegan $count resultados: ${describe(session)}") {
            session.state.value.conversation.items.count { it.kind is Kind.Result } == count
        }
    }

    private suspend fun awaitIdle(session: PersistentAgentSession) {
        eventually("el turno termina: ${describe(session)}") {
            val conversation = session.state.value.conversation
            conversation.status == AgentStatus.Idle && conversation.items.any { it.kind is Kind.Result }
        }
    }

    private fun describe(session: PersistentAgentSession): String {
        val state: PersistentAgentSessionState = session.state.value
        return "attached=${state.isAttached} alive=${state.isAlive} error=${state.lastError} items=${state.conversation.items.size}"
    }

    private fun assistantTexts(session: PersistentAgentSession): List<String> =
        session.state.value.conversation.items.mapNotNull { (it.kind as? Kind.AssistantText)?.text }.filterNot { "permiso para crear" in it }

    private fun userTexts(session: PersistentAgentSession): List<String> =
        session.state.value.conversation.items.mapNotNull { (it.kind as? Kind.UserText)?.text }

    private fun agentDirectory(session: PersistentAgentSession): Path =
        server.home.resolve(PersistentAgentScript.ROOT_RELATIVE_PATH).resolve(session.id)

    private fun logText(session: PersistentAgentSession): String = agentDirectory(session).resolve("out.ndjson").readText()

    private fun recordedOrNull(session: PersistentAgentSession, kind: String): String? =
        server.home.resolve(FakeClaude.TEST_DIRECTORY).resolve("${session.id}.$kind").takeIf { it.exists() }?.readText()

    private suspend fun recorded(session: PersistentAgentSession, kind: String): String {
        eventually("el simulado registró $kind") { recordedOrNull(session, kind) != null }
        return recordedOrNull(session, kind).orEmpty()
    }

    private fun pidOf(session: PersistentAgentSession): String = agentDirectory(session).resolve("pid").readText().trim()

    private fun isRunning(pid: String): Boolean {
        val line = server.runLocal("ps -o stat= -p $pid").trim()
        return line.isNotEmpty() && !line.startsWith("Z")
    }

    private fun kill(pid: String) {
        server.runLocal("kill -9 $pid 2>/dev/null; true")
    }

    private fun tailProcesses(): List<String> = server.agentProcesses().filter { " tail " in it }

    private fun String.count(needle: String): Int = windowed(needle.length).count { it == needle }

    private fun assumeNoSystemClaude() {
        val found = server.runLocal(AgentExecCommands.LOCATE_CLAUDE_SCRIPT).trim()
        assumeTrue(found.isEmpty(), "Esta máquina tiene un claude en una ruta fija: $found")
    }

    private fun agentTest(block: suspend CoroutineScope.() -> Unit) = runBlocking<Unit> {
        withTimeout(TEST_TIMEOUT_MILLIS) { block() }
    }

    private companion object {
        const val TEST_TIMEOUT_MILLIS = 90_000L
        const val SETTLE_MILLIS = 500L
        const val FIRST_NOTES = "notas-argos-1.md"
        const val TOKEN_NEEDLE = "AGUJA9TOKEN"
        const val RAPID_REATTACH = 5
    }
}
