package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.PersistentAgentInfo
import com.iaportafolio.argos.core.agent.PersistentAgentMeta
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.data.AgentPermissionBackend
import com.iaportafolio.argos.data.ClaudeTokenStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import java.io.IOException
import java.time.Instant
import java.util.Base64

const val AGENT_1 = "11111111-1111-1111-1111-111111111111"
const val AGENT_2 = "22222222-2222-2222-2222-222222222222"
const val AGENT_3 = "33333333-3333-3333-3333-333333333333"

/** Con la forma real de un token, para comprobar también el tapado por patrón. */
const val SECRET_TOKEN = "sk-ant-oat01-SECRETOTOKEN1234567890"

fun agentInfo(
    id: String = AGENT_1,
    path: String = "/srv/api",
    title: String = "api",
    isAlive: Boolean = true,
    logBytes: Long = 0,
    createdAt: Instant = Instant.ofEpochSecond(1_700_000_000),
    permissionMode: String? = null,
) = PersistentAgentInfo(id, isAlive, logBytes, PersistentAgentMeta(path, title, createdAt, permissionMode))

/** Un enganche al log en curso: el test emite líneas y decide cuándo y cómo termina. */
class AgentAttachCall(val command: String, private val output: suspend (ByteArray) -> Unit) {
    /** Completar con `null` = EOF; con una excepción = caída. */
    val end = CompletableDeferred<Exception?>()
    var cancelled = false
    var closed = false

    suspend fun emit(vararg lines: String) = output(lines.joinToString("") { "$it\n" }.toByteArray())
}

class AgentLaunchCall(val command: String, val stdinFirstChunk: String)

/** [SSHServicing] de tmux ([FakeSSHService]) + scripts y canal exec del agente. */
class FakeAgentService(base: FakeSSHService = FakeSSHService()) : SSHServicing by base, AgentExecStreaming {
    var agents: List<PersistentAgentInfo> = emptyList()
    var claudePath: String? = "/usr/local/bin/claude"
    var authStatus: ClaudeAuthStatus? = ClaudeAuthStatus(loggedIn = true, subscriptionType = "max", email = "yo@example.com")
    var authError: Exception? = null
    var authCalls = 0

    /** Fallo de los scripts de lista / de los demás (enviar, parar, borrar). */
    var listError: Exception? = null
    var scriptError: Exception? = null
    val scripts = mutableListOf<String>()

    var launchReply = "4242\n"
    var launchError: Exception? = null
    val launches = mutableListOf<AgentLaunchCall>()

    val attaches = mutableListOf<AgentAttachCall>()
    val attachOpenErrors = ArrayDeque<Exception>()

    override suspend fun locateClaude(): String? = claudePath

    override suspend fun runAgentScript(command: String): String {
        if (command == PersistentAgentScript.list()) {
            listError?.let { throw it }
            return agents.joinToString("") { listLine(it) }
        }
        scripts += command
        scriptError?.let { throw it }
        agents = agents.mapNotNull { info ->
            when (command) {
                PersistentAgentScript.stop(info.id, delete = false) -> info.copy(isAlive = false)
                PersistentAgentScript.stop(info.id, delete = true) -> null
                else -> info
            }
        }
        return ""
    }

    override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
        if ("read -r ARGOS_OAUTH" in command) {
            launches += AgentLaunchCall(command, stdin.first().decodeToString())
            launchError?.let { throw it }
            output(launchReply.toByteArray())
            return
        }
        attachOpenErrors.removeFirstOrNull()?.let { throw it }
        val call = AgentAttachCall(command, output)
        attaches += call
        try {
            call.end.await()?.let { throw it }
        } catch (cancel: CancellationException) {
            call.cancelled = true
            throw cancel
        } finally {
            call.closed = true
        }
    }

    override suspend fun claudeAuthStatus(): ClaudeAuthStatus? {
        authCalls++
        authError?.let { throw it }
        return authStatus
    }

    private fun listLine(info: PersistentAgentInfo): String {
        val meta = Base64.getEncoder().encodeToString(PersistentAgentMeta.encode(info.meta).toByteArray())
        return "${info.id}|${if (info.isAlive) 1 else 0}|${info.logBytes}|$meta\n"
    }
}

/** Lo que habría en `SharedPreferences`: los tests usan el [AgentPermissionStore] real. */
class InMemoryAgentPermissionBackend(initial: Map<String, String> = emptyMap()) : AgentPermissionBackend {
    val saved = initial.toMutableMap()

    override fun readAll(): Map<String, String> = saved.toMap()

    override fun write(key: String, value: String?) {
        if (value == null) saved.remove(key) else saved[key] = value
    }
}

class InMemoryClaudeTokens(var token: String? = null) : ClaudeTokenStore {
    var readError: Exception? = null
    var saveError: Exception? = null
    var reads = 0

    override fun hasToken(): Boolean = token != null

    override fun read(): String? {
        reads++
        readError?.let { throw it }
        return token
    }

    override fun save(token: String) {
        saveError?.let { throw it }
        this.token = token
    }

    override fun delete() {
        token = null
    }
}

/** Líneas NDJSON del log, como las escribe `claude` y `PersistentAgentScript.send`. */
object AgentLog {
    fun user(text: String) = """{"type":"user","message":{"content":${quote(text)}}}"""

    fun assistant(text: String) = """{"type":"assistant","message":{"content":[{"type":"text","text":${quote(text)}}]}}"""

    fun toolUse(name: String, inputJson: String) =
        """{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"$name","input":$inputJson}]}}"""

    fun result() = """{"type":"result","subtype":"success","is_error":false,"result":"ok"}"""

    fun permission(id: String, tool: String = "Bash", inputJson: String = """{"command":"rm -rf build"}""") =
        """{"type":"control_request","request_id":"$id","request":{"subtype":"can_use_tool","tool_name":"$tool","input":$inputJson}}"""

    fun answered(id: String) = """{"type":"${PersistentAgentScript.ANSWERED_EVENT_TYPE}","request_id":"$id"}"""

    private fun quote(text: String) = "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}

/** Un error de red cualquiera. */
fun networkDown() = IOException("Sin red")
