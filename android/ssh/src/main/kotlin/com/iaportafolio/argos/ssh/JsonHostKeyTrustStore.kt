package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.HostKeyTrustStore
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap

/**
 * Almacén TOFU en un archivo JSON `{"host:port":"SHA256:..."}`: el mismo formato que el
 * `known_hosts.json` de Apple (port de la persistencia de `TOFUHostKeyValidator`).
 *
 * - Lectura tolerante: archivo inexistente = vacío (primer uso). Archivo corrupto = vacío,
 *   como en Apple, pero se notifica por [onCorrupt] para que la app lo registre (devolver
 *   vacío re-confía en todos los hosts: es relevante para la seguridad).
 * - Escritura atómica: temporal en el mismo directorio + `move` atómico.
 * - Exclusión por archivo y por PROCESO (no por instancia): varias instancias sobre la misma
 *   ruta comparten el lock, como el `fileLock` estático de Apple.
 *
 * Bloqueante (E/S de disco): la verificación de sshj ya corre en su hilo de transporte.
 */
class JsonHostKeyTrustStore(
    private val file: Path,
    private val onCorrupt: (Path, Exception) -> Unit = { _, _ -> },
) : HostKeyTrustStore {

    private val lock: Any = LOCKS.computeIfAbsent(file.toAbsolutePath().normalize()) { Any() }

    override fun trustedFingerprint(endpoint: String): String? = synchronized(lock) { load()[endpoint] }

    override fun trust(endpoint: String, fingerprint: String) {
        synchronized(lock) {
            val known = load()
            if (known[endpoint] != fingerprint) save(known + (endpoint to fingerprint))
        }
    }

    override fun forget(endpoint: String) {
        synchronized(lock) {
            val known = load()
            if (endpoint in known) save(known - endpoint)
        }
    }

    /** Todas las huellas confiadas (`host:port` → `SHA256:…`). */
    fun allTrusted(): Map<String, String> = synchronized(lock) { load() }

    /**
     * Fija la huella de un endpoint recibida por QR desde el Mac, SOLO si no había otra: un QR
     * nunca debe poder cambiar la identidad de un servidor conocido (abriría la puerta a un
     * MitM). Devuelve `false` si ya había una huella distinta (que se conserva).
     */
    fun trustIfUnknown(endpoint: String, fingerprint: String): Boolean = synchronized(lock) {
        val known = load()
        when (known[endpoint]) {
            null -> {
                save(known + (endpoint to fingerprint))
                true
            }
            fingerprint -> true
            else -> false
        }
    }

    private fun load(): Map<String, String> {
        val text = try {
            Files.readString(file)
        } catch (_: NoSuchFileException) {
            return emptyMap()
        }
        return try {
            val root = Json.parseToJsonElement(text) as? JsonObject
                ?: throw SerializationException("known_hosts no es un objeto JSON")
            root.mapValues { (endpoint, value) ->
                (value as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                    ?: throw SerializationException("Huella no válida para $endpoint")
            }
        } catch (error: SerializationException) {
            onCorrupt(file, error)
            emptyMap()
        }
    }

    private fun save(known: Map<String, String>) {
        val json = JsonObject(known.toSortedMap().mapValues { JsonPrimitive(it.value) }).toString()
        val directory = file.toAbsolutePath().parent
        Files.createDirectories(directory)
        val temp = Files.createTempFile(directory, ".known_hosts", ".tmp")
        try {
            Files.writeString(temp, json)
            try {
                Files.move(temp, file, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temp, file, StandardCopyOption.REPLACE_EXISTING)
            }
        } catch (error: IOException) {
            Files.deleteIfExists(temp)
            throw error
        }
    }

    private companion object {
        val LOCKS = ConcurrentHashMap<Path, Any>()
    }
}
