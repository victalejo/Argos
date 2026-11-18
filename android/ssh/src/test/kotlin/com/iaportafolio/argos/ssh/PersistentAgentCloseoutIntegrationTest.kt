package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.AgentStatus
import com.iaportafolio.argos.core.agent.AgentTranscriptItem.Kind
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.PersistentAgentInfo
import com.iaportafolio.argos.core.agent.PersistentAgentMeta
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.core.agent.PersistentAgentSession
import com.iaportafolio.argos.core.agent.PersistentAgentShell
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import com.iaportafolio.argos.ssh.testing.FakeClaude
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.UUID
import kotlin.io.path.createDirectories
import kotlin.io.path.readText
import kotlin.io.path.writeText
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Cierre de flecos de punta a punta (sshj → MINA SSHD → scripts reales → `claude` SIMULADO), como
 * `ArgosTests/IntegrationAgentCloseoutTests.swift`: «Detener» el turno, el claude que muere después
 * del segundo de gracia del lanzador y engancharse de cero a un log rotado.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class PersistentAgentCloseoutIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService
    private lateinit var project: Path
    private lateinit var scope: CoroutineScope

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(dir.resolve("server")), password = AGENT_TEST_PASSWORD)
        project = server.home.resolve("proyectos/cierre").createDirectories()
    }

    @BeforeEach
    fun setUp() {
        FakeClaude.install(server.home, testMode = true)
        FakeClaude.verifyResolves(server)
        service = agentService(server)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

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

    @Test
    fun `detener el turno lo cierra, el agente sigue vivo y acepta otro mensaje`() = agentTest {
        val session = PersistentAgentSession.launch(service, service, project.toString(), "t", null, scope)
        session.attach()
        session.send("una tarea #abierto")
        eventually("el turno abierto empieza: ${describe(session)}") {
            assistantTexts(session).any { "Trabajando sin fin" in it }
        }
        assertEquals(AgentStatus.Working, session.state.value.conversation.status)

        assertTrue(session.interrupt())
        eventually("el turno se cierra: ${describe(session)}") {
            val state = session.state.value
            !state.isInterrupting && state.conversation.status == AgentStatus.Idle
        }
        assertTrue(session.state.value.isAlive)
        assertTrue(onlyAgent().isAlive)
        assertContains(logText(session), "\"control_response\"")
        // Sin turno en curso no se manda otra interrupción.
        assertEquals(false, session.interrupt())

        session.send("otra")
        eventually("responde al siguiente: ${describe(session)}") {
            assistantTexts(session).any { "| 2 | hecho |" in it } && session.state.value.conversation.status == AgentStatus.Idle
        }
        assertTrue(onlyAgent().isAlive)
    }

    @Test
    fun `un claude que muere despues del arranque se detecta y se explica`() = agentTest {
        val id = UUID.randomUUID().toString().lowercase()
        val meta = PersistentAgentMeta(project.toString(), "t", Instant.now())
        val dir = server.home.resolve(PersistentAgentScript.ROOT_RELATIVE_PATH).resolve(id).createDirectories()
        dir.resolve("meta.json").writeText(PersistentAgentMeta.encode(meta))
        dir.resolve("out.ndjson").writeText("")
        dir.resolve("err.log").writeText("error: not logged in\n")
        // El lanzador «responde su PID» (claude aún vivo al segundo) y muere después: no hay pid.
        val exec = object : AgentExecStreaming {
            override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
                output("4242\n".toByteArray())
            }

            override suspend fun claudeAuthStatus(): ClaudeAuthStatus? = null
        }
        val session = PersistentAgentSession(service, exec, PersistentAgentInfo(id, false, 0, meta), scope)
        assertTrue(session.resume(null))
        assertTrue(session.state.value.isAlive)
        eventually("se detecta que murió: ${describe(session)}") {
            !session.state.value.isAlive && session.state.value.lastError != null
        }
        assertContains(session.state.value.lastError.orEmpty(), "error: not logged in")
    }

    @Test
    fun `engancharse de cero a un log rotado reconstruye lo conservado sin reengancharse sin fin`() = agentTest {
        val writer = PersistentAgentSession.launch(service, service, project.toString(), "t", null, scope)
        writer.attach()
        writer.send("uno")
        eventually("pide permiso") { writer.state.value.conversation.pendingPermission != null }
        writer.allowPendingPermission()
        writer.send("dos")
        eventually("dos turnos: ${describe(writer)}") {
            writer.state.value.conversation.items.count { it.kind is Kind.Result } == 2
        }
        writer.stop()
        writer.detach()
        val directory = PersistentAgentScript.directory(writer.id)
        val total = Files.size(agentDir(writer.id).resolve("out.ndjson"))
        service.runAgentScript(PersistentAgentShell.rotateOutputLog(directory, 200, 900))
        assertTrue(logText(writer).startsWith(PersistentAgentShell.ROTATED_LINE + "\n"))

        val info = assertNotNull(PersistentAgentSession.list(service).firstOrNull { it.id == writer.id })
        assertEquals(total, info.logBytes)
        val session = PersistentAgentSession(service, service, info, scope)
        session.attach()
        eventually("lee hasta el final: ${session.state.value.receivedBytes} de $total") {
            session.state.value.receivedBytes == total
        }
        assertTrue(assistantTexts(session).last().contains("| 2 | hecho |"))
        // Estable: ni se reengancha ni cuenta de más (la marca inicial no llega).
        val items = session.state.value.conversation.items.size
        delay(STABLE_MILLIS)
        assertEquals(total, session.state.value.receivedBytes)
        assertEquals(items, session.state.value.conversation.items.size)
        assertTrue(session.state.value.isAttached)
    }

    // MARK: Utilidades

    private suspend fun onlyAgent(): PersistentAgentInfo = PersistentAgentSession.list(service).single()

    private fun agentDir(id: String): Path = server.home.resolve(PersistentAgentScript.ROOT_RELATIVE_PATH).resolve(id)

    private fun logText(session: PersistentAgentSession): String = agentDir(session.id).resolve("out.ndjson").readText()

    private fun assistantTexts(session: PersistentAgentSession): List<String> =
        session.state.value.conversation.items.mapNotNull { (it.kind as? Kind.AssistantText)?.text }

    private fun describe(session: PersistentAgentSession): String {
        val state = session.state.value
        return "alive=${state.isAlive} interrupting=${state.isInterrupting} status=${state.conversation.status} " +
            "error=${state.lastError} items=${state.conversation.items.size}"
    }

    private fun agentTest(block: suspend CoroutineScope.() -> Unit) = runBlocking<Unit> {
        withTimeout(TEST_TIMEOUT_MILLIS) { block() }
    }

    private companion object {
        const val TEST_TIMEOUT_MILLIS = 90_000L
        const val STABLE_MILLIS = 2_000L
    }
}
