package com.iaportafolio.argos.background

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.iaportafolio.argos.data.ArgosLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.SetSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** Dónde se guarda el estado: clave → texto, sin Android para poder probarlo en la JVM. */
interface AgentWatchBackend {
    fun read(key: String): String?

    /** `null` borra la clave. */
    fun write(key: String, value: String?)
}

/**
 * Qué servidores usan agentes y cuánto log se ha visto de cada agente (equivale a `agents.servers`
 * y `agents.seenBytes` de iOS). Lo escriben el worker, el servicio y la UI: todo va bajo un monitor.
 */
class AgentWatchStore(private val backend: AgentWatchBackend) {

    private val lock = Any()
    private var servers: Set<String> = decode(KEY_SERVERS, SERVERS_SERIALIZER).orEmpty()
    private var seen: Map<String, Map<String, Long>> = decode(KEY_SEEN, SEEN_SERIALIZER).orEmpty()
    private val enabledState = MutableStateFlow(backend.read(KEY_ENABLED) != FALSE)

    /** Avisos activados en Argos (por defecto, sí). */
    val notificationsEnabled: StateFlow<Boolean> = enabledState.asStateFlow()

    fun setNotificationsEnabled(enabled: Boolean) {
        enabledState.value = enabled
        backend.write(KEY_ENABLED, if (enabled) null else FALSE)
    }

    /** Devuelve `true` solo la primera vez: el permiso se pide una vez y no se insiste. */
    fun claimPermissionRequest(): Boolean = synchronized(lock) {
        if (backend.read(KEY_PERMISSION_ASKED) != null) return false
        backend.write(KEY_PERMISSION_ASKED, TRUE)
        true
    }

    fun watchedServers(): Set<String> = synchronized(lock) { servers }

    fun watch(serverId: String) = synchronized(lock) {
        if (serverId !in servers) saveServers(servers + serverId)
    }

    /** Deja de revisar el servidor y olvida lo visto. Devuelve los agentes que se conocían. */
    fun unwatch(serverId: String): Set<String> = synchronized(lock) {
        val agents = seen[serverId]?.keys.orEmpty()
        if (serverId in servers) saveServers(servers - serverId)
        if (serverId in seen) saveSeen(seen - serverId)
        agents
    }

    fun seenBytes(serverId: String): Map<String, Long> = synchronized(lock) { seen[serverId].orEmpty() }

    /** El usuario leyó hasta [bytes]. Nunca retrocede. Sin servidor apuntado no se guarda nada. */
    fun markSeen(serverId: String, agentId: String, bytes: Long) = synchronized(lock) {
        if (serverId !in servers || bytes <= 0) return@synchronized
        val current = seen[serverId].orEmpty()
        if (bytes > (current[agentId] ?: 0)) saveSeen(seen + (serverId to current + (agentId to bytes)))
    }

    /**
     * Guarda el resultado de una comprobación que partió de [before]. Si entretanto un chat marcó
     * más bytes, se conservan; solo se olvidan los agentes que estaban en [before] y ya no existen.
     */
    fun applyCheck(serverId: String, before: Map<String, Long>, planned: Map<String, Long>) = synchronized(lock) {
        if (serverId !in servers) return@synchronized
        val current = seen[serverId].orEmpty()
        val kept = current - (before.keys - planned.keys)
        val merged = kept + planned.mapValues { (agent, bytes) -> maxOf(bytes, kept[agent] ?: 0) }
        if (merged != current) saveSeen(seen + (serverId to merged))
    }

    private fun saveServers(updated: Set<String>) {
        servers = updated
        backend.write(KEY_SERVERS, JSON.encodeToString(SERVERS_SERIALIZER, updated))
    }

    private fun saveSeen(updated: Map<String, Map<String, Long>>) {
        seen = updated
        backend.write(KEY_SEEN, JSON.encodeToString(SEEN_SERIALIZER, updated))
    }

    private fun <T> decode(key: String, serializer: kotlinx.serialization.KSerializer<T>): T? {
        val text = backend.read(key) ?: return null
        return try {
            JSON.decodeFromString(serializer, text)
        } catch (error: SerializationException) {
            ArgosLog.warn(ArgosLog.TAG_STORE, "$key no es válido; se ignora (${error::class.java.simpleName})")
            null
        } catch (error: IllegalArgumentException) {
            ArgosLog.warn(ArgosLog.TAG_STORE, "$key no es válido; se ignora (${error::class.java.simpleName})")
            null
        }
    }

    private companion object {
        const val KEY_SERVERS = "agents.servers"
        const val KEY_SEEN = "agents.seenBytes"
        const val KEY_ENABLED = "agents.notificationsEnabled"
        const val KEY_PERMISSION_ASKED = "agents.notificationPermissionAsked"
        const val TRUE = "true"
        const val FALSE = "false"
        val JSON = Json
        val SERVERS_SERIALIZER = SetSerializer(String.serializer())
        val SEEN_SERIALIZER = MapSerializer(String.serializer(), MapSerializer(String.serializer(), Long.serializer()))
    }
}

/** [AgentWatchBackend] sobre `SharedPreferences`, excluido de las copias como todo lo local. */
class SharedPreferencesAgentWatch(context: Context) : AgentWatchBackend {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun read(key: String): String? = prefs.getString(key, null)

    override fun write(key: String, value: String?) = prefs.edit {
        if (value == null) remove(key) else putString(key, value)
    }

    private companion object {
        const val FILE = "agent_watch"
    }
}
