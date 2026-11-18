package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.status.ClaudeActivitySnapshot
import com.iaportafolio.argos.data.ArgosLog
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.SetSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Claude Code en las ventanas tmux (equivale a `claude.servers` y `claude.snapshots` de iOS): en qué
 * servidores se vio Claude (se revisan en segundo plano) y la última lectura de cada uno, que es la
 * referencia para saber qué es NUEVO. La escriben el sondeo de primer plano y el worker: todo bajo un
 * monitor, en el mismo `SharedPreferences` que los avisos de agentes.
 */
class ClaudeWatchStore(private val backend: AgentWatchBackend) {

    private val lock = Any()
    private var servers: Set<String> = decode(KEY_SERVERS, SERVERS_SERIALIZER).orEmpty()
    private var snapshots: Map<String, ClaudeActivitySnapshot> = decode(KEY_SNAPSHOTS, SNAPSHOTS_SERIALIZER).orEmpty()
    private var hintDismissed: Set<String> = decode(KEY_HINT_DISMISSED, SERVERS_SERIALIZER).orEmpty()

    fun watchedServers(): Set<String> = synchronized(lock) { servers }

    /** Se vio Claude en el servidor. `true` solo la primera vez (para pedir el permiso de avisos). */
    fun watch(serverId: String): Boolean = synchronized(lock) {
        if (serverId in servers) return false
        servers = servers + serverId
        backend.write(KEY_SERVERS, JSON.encodeToString(SERVERS_SERIALIZER, servers))
        true
    }

    /** Última lectura guardada (`null` si nunca se leyó: no se sabe qué es nuevo). */
    fun snapshot(serverId: String): ClaudeActivitySnapshot? = synchronized(lock) { snapshots[serverId] }

    fun save(serverId: String, snapshot: ClaudeActivitySnapshot) = synchronized(lock) {
        if (snapshots[serverId] == snapshot) return@synchronized
        saveSnapshots(snapshots + (serverId to snapshot))
    }

    /** Servidor borrado: deja de revisarse y se olvida su lectura. */
    fun forget(serverId: String) = synchronized(lock) {
        if (serverId in servers) {
            servers = servers - serverId
            backend.write(KEY_SERVERS, JSON.encodeToString(SERVERS_SERIALIZER, servers))
        }
        if (serverId in snapshots) saveSnapshots(snapshots - serverId)
    }

    /** «Ahora no» en la sugerencia de activar el indicador de ese servidor. */
    fun isHooksHintDismissed(serverId: String): Boolean = synchronized(lock) { serverId in hintDismissed }

    fun dismissHooksHint(serverId: String) = synchronized(lock) {
        if (serverId in hintDismissed) return@synchronized
        hintDismissed = hintDismissed + serverId
        backend.write(KEY_HINT_DISMISSED, JSON.encodeToString(SERVERS_SERIALIZER, hintDismissed))
    }

    private fun saveSnapshots(updated: Map<String, ClaudeActivitySnapshot>) {
        snapshots = updated
        backend.write(KEY_SNAPSHOTS, JSON.encodeToString(SNAPSHOTS_SERIALIZER, updated))
    }

    private fun <T> decode(key: String, serializer: KSerializer<T>): T? {
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
        const val KEY_SERVERS = "claude.servers"
        const val KEY_SNAPSHOTS = "claude.snapshots"
        const val KEY_HINT_DISMISSED = "claude.hooksHintDismissed"
        val JSON = Json { ignoreUnknownKeys = true }
        val SERVERS_SERIALIZER = SetSerializer(String.serializer())
        val SNAPSHOTS_SERIALIZER = MapSerializer(String.serializer(), ClaudeActivitySnapshot.serializer())
    }
}
