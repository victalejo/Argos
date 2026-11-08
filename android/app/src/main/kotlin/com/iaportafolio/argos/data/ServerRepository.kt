package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.Server
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.io.IOException

/** Servidores configurados por el usuario (equivale a `ServerStore` de Apple). */
interface ServerRepository {
    val servers: StateFlow<List<Server>>

    fun server(id: String): Server? = servers.value.firstOrNull { it.id == id }

    /** Inserta o reemplaza (por [Server.id]) y persiste. Lanza [IOException] si no se puede escribir. */
    suspend fun upsert(server: Server)

    /** Borra el servidor con ese id (no hace nada si no existe) y persiste. */
    suspend fun delete(id: String)
}

/**
 * [ServerRepository] sobre `servers.json`: un array JSON de [Server] con [Server.JSON], el
 * MISMO formato que el `servers.json` de Apple. Escritura atómica y serializada con un
 * [Mutex]; el [StateFlow] solo cambia si el disco se actualizó.
 *
 * Si el archivo existente está corrupto NO se sobrescribe: se aparta como
 * `servers.json.corrupt-<epoch>` (para poder recuperarlo) y se empieza con la lista vacía.
 */
class FileServerRepository(
    private val file: File,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = System::currentTimeMillis,
) : ServerRepository {

    private val serializer = ListSerializer(Server.serializer())
    private val mutex = Mutex()
    private val state = MutableStateFlow(load())

    override val servers: StateFlow<List<Server>> = state.asStateFlow()

    override suspend fun upsert(server: Server) = mutate { current ->
        val index = current.indexOfFirst { it.id == server.id }
        if (index < 0) current + server else current.mapIndexed { i, old -> if (i == index) server else old }
    }

    override suspend fun delete(id: String) = mutate { current -> current.filterNot { it.id == id } }

    private suspend fun mutate(transform: (List<Server>) -> List<Server>) {
        mutex.withLock {
            val updated = transform(state.value)
            if (updated == state.value) return
            withContext(io) {
                AtomicFiles.write(file, Server.JSON.encodeToString(serializer, updated).encodeToByteArray())
            }
            state.value = updated
        }
    }

    private fun load(): List<Server> {
        if (!file.exists()) return emptyList()
        return try {
            Server.JSON.decodeFromString(serializer, file.readText())
        } catch (error: SerializationException) {
            quarantine(error)
        } catch (error: IllegalArgumentException) {
            quarantine(error)
        } catch (error: IOException) {
            ArgosLog.error(ArgosLog.TAG_STORE, "No se pudo leer ${file.name}", error)
            emptyList()
        }
    }

    private fun quarantine(error: Throwable): List<Server> {
        val aside = File(file.parentFile, "${file.name}.corrupt-${clock()}")
        val moved = file.renameTo(aside)
        ArgosLog.error(
            ArgosLog.TAG_STORE,
            "${file.name} no es válido; " + if (moved) "apartado como ${aside.name}" else "no se pudo apartar",
            error,
        )
        return emptyList()
    }
}
