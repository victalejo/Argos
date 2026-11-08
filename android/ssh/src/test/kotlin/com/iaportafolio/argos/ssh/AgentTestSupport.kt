package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.flow.Flow
import java.util.concurrent.CopyOnWriteArrayList

const val AGENT_TEST_PASSWORD = "argos-test"

/** Servicio nuevo (con su propia conexión) contra el servidor embebido, o a través de [port]. */
fun agentService(server: EmbeddedSshServer, port: Int = server.port): SshjSSHService = SshjConnector().service(
    testServer(port),
    SSHCredentials.Password(AGENT_TEST_PASSWORD),
    InMemoryTrustStore(),
) as SshjSSHService

/** Hilos que siguen dentro del canal exec del agente (lectores colgados = fuga). */
fun agentExecThreads(): List<String> = threadsInside(SshjAgentExec::class.java.name)

private fun threadsInside(className: String): List<String> = Thread.getAllStackTraces()
    .filter { (_, frames) -> frames.any { it.className.substringBefore('$') == className } }
    .map { (thread, _) -> thread.name }

/** Hilos de sshj (lector de transporte, keep-alive…): si sobran, una conexión quedó abierta. */
fun sshjThreads(): List<String> = Thread.getAllStackTraces().keys.map { it.name }.filter { it.startsWith("sshj-") }

/**
 * Pasa por el [AgentExecStreaming] real anotando cada comando y cada callback de salida, para
 * comprobar lo que viaja en la línea de comandos e inyectar la salida tardía de un `tail` viejo.
 */
class RecordingAgentExec(private val delegate: AgentExecStreaming) : AgentExecStreaming {
    val commands: MutableList<String> = CopyOnWriteArrayList()
    val outputs: MutableList<suspend (ByteArray) -> Unit> = CopyOnWriteArrayList()

    override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
        commands += command
        outputs += output
        delegate.runAgentExec(command, stdin, output)
    }

    override suspend fun claudeAuthStatus() = delegate.claudeAuthStatus()
}
