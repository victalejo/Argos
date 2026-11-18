package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.github.CIWatch
import com.iaportafolio.argos.data.ArgosLog
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.time.Instant

/**
 * Commits cuyo CI se vigila, por servidor, guardados en el dispositivo para que el worker los
 * siga revisando aunque el proceso muera. Solo rutas, nombre de proyecto y sha: nada secreto.
 */
class CIWatchStore(private val backend: AgentWatchBackend) {

    @Serializable
    private data class Stored(val root: String, val name: String, val sha: String? = null, val since: Long)

    fun load(): Map<String, Map<String, CIWatch>> {
        val text = backend.read(KEY) ?: return emptyMap()
        return try {
            JSON.decodeFromString(SERIALIZER, text).mapValues { (_, watches) ->
                watches.associate { it.root to CIWatch(it.root, it.name, it.sha, Instant.ofEpochMilli(it.since)) }
            }.filterValues { it.isNotEmpty() }
        } catch (error: SerializationException) {
            ArgosLog.warn(ArgosLog.TAG_STORE, "$KEY no es válido; se ignora (${error::class.java.simpleName})")
            emptyMap()
        } catch (error: IllegalArgumentException) {
            ArgosLog.warn(ArgosLog.TAG_STORE, "$KEY no es válido; se ignora (${error::class.java.simpleName})")
            emptyMap()
        }
    }

    fun save(watches: Map<String, Map<String, CIWatch>>) {
        val stored = watches.filterValues { it.isNotEmpty() }.mapValues { (_, byRoot) ->
            byRoot.values.sortedBy { it.root }.map { Stored(it.root, it.name, it.sha, it.since.toEpochMilli()) }
        }
        backend.write(KEY, if (stored.isEmpty()) null else JSON.encodeToString(SERIALIZER, stored))
    }

    private companion object {
        const val KEY = "ci.watches"
        val JSON = Json { ignoreUnknownKeys = true }
        val SERIALIZER = MapSerializer(String.serializer(), ListSerializer(Stored.serializer()))
    }
}
