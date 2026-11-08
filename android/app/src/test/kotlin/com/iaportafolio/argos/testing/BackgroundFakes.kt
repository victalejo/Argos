package com.iaportafolio.argos.testing

import com.iaportafolio.argos.background.AgentAlert
import com.iaportafolio.argos.background.AgentAlertSink
import com.iaportafolio.argos.background.AgentAttentionTracker
import com.iaportafolio.argos.background.AgentCheckScheduler
import com.iaportafolio.argos.background.AgentWatchBackend
import com.iaportafolio.argos.background.TerminalKeepAliveHost
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.agent.PersistentAgentMeta
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.time.Instant
import java.util.Base64

class InMemoryAgentWatchBackend(initial: Map<String, String> = emptyMap()) : AgentWatchBackend {
    val saved = initial.toMutableMap()

    override fun read(key: String): String? = saved[key]

    override fun write(key: String, value: String?) {
        if (value == null) saved.remove(key) else saved[key] = value
    }
}

class RecordingAlerts(var allowed: Boolean = true) : AgentAlertSink {
    val posted = mutableListOf<AgentAlert>()
    val cancelled = mutableListOf<Pair<String, String>>()

    override fun canNotify(): Boolean = allowed

    override fun post(alert: AgentAlert) {
        posted += alert
    }

    override fun cancel(serverId: String, agentId: String) {
        cancelled += serverId to agentId
    }
}

class RecordingScheduler : AgentCheckScheduler {
    var scheduled = 0
    var cancelled = 0

    override fun schedule() {
        scheduled++
    }

    override fun cancel() {
        cancelled++
    }
}

/** Una línea de `PersistentAgentScript.snapshots()`, como la imprime el servidor. */
fun snapshotLine(
    id: String = AGENT_1,
    title: String = "api",
    logBytes: Long = 100,
    tail: String = AgentLog.result(),
    createdAt: Instant = Instant.parse("2026-01-01T00:00:00Z"),
): String {
    val meta = PersistentAgentMeta("/srv/api", title, createdAt)
    val encoder = Base64.getEncoder()
    return "$id|1|$logBytes|${encoder.encodeToString(PersistentAgentMeta.encode(meta).toByteArray())}|${encoder.encodeToString(tail.toByteArray())}\n"
}

/** Servicio de un servidor en la comprobación de avisos. */
class SnapshotService(var output: String = "", var error: Exception? = null) : SSHServicing by FakeSSHService() {
    /** Si no es null, el script no responde hasta que se complete. */
    var gate: CompletableDeferred<Unit>? = null
    val scripts = mutableListOf<String>()
    var disconnects = 0

    override suspend fun runAgentScript(command: String): String {
        scripts += command
        gate?.await()
        error?.let { throw it }
        return output
    }

    override suspend fun disconnect() {
        disconnects++
    }
}

/** Conector con un servicio por servidor; recuerda con qué se le llamó. */
class FakeConnector(private val services: Map<String, SSHServicing>) : SSHConnector {
    val opened = mutableListOf<String>()
    val trustStores = mutableListOf<HostKeyTrustStore>()
    var error: Exception? = null

    override fun service(server: Server, credentials: SSHCredentials, trust: HostKeyTrustStore): SSHServicing {
        opened += server.id
        trustStores += trust
        error?.let { throw it }
        return services.getValue(server.id)
    }
}

class RecordingAttention(enabled: Boolean = true) : AgentAttentionTracker {
    private val state = MutableStateFlow(enabled)
    val opened = mutableListOf<String>()
    val shown = mutableListOf<Pair<String, String>>()
    val hidden = mutableListOf<Triple<String, String, Long>>()
    val deleted = mutableListOf<String>()

    override val notificationsEnabled: StateFlow<Boolean> = state

    override fun setNotificationsEnabled(enabled: Boolean) {
        state.value = enabled
    }

    override fun agentOpened(serverId: String) {
        opened += serverId
    }

    override fun chatShown(serverId: String, agentId: String) {
        shown += serverId to agentId
    }

    override fun chatHidden(serverId: String, agentId: String, receivedBytes: Long) {
        hidden += Triple(serverId, agentId, receivedBytes)
    }

    override fun serverDeleted(serverId: String) {
        deleted += serverId
    }
}

class FakeKeepAliveHost(var allowed: Boolean = true) : TerminalKeepAliveHost {
    var starts = 0

    override fun start(): Boolean {
        starts++
        return allowed
    }
}

/** Referencia a [PersistentAgentScript.snapshots] para los fakes de comprobación. */
val SNAPSHOTS_COMMAND: String = PersistentAgentScript.snapshots()
