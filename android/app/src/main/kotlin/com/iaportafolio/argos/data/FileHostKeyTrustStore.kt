package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.HostKeyTrustStore
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException

/**
 * Huellas TOFU en `known_hosts.json`: `{"host:port":"SHA256:..."}`, el mismo formato que el
 * `known_hosts.json` de Apple (`TOFUHostKeyValidator`).
 *
 * Seguro entre hilos: la verificación llega desde el hilo de transporte del cliente SSH y el
 * «Olvidar host key» desde la UI. Todo pasa por un único monitor; el mapa en memoria es
 * inmutable y se reemplaza entero tras escribir el disco (si la escritura falla, la memoria
 * no cambia y se registra el error).
 */
class FileHostKeyTrustStore(private val file: File) : HostKeyTrustStore {

    private val serializer = MapSerializer(String.serializer(), String.serializer())
    private val json = Json { prettyPrint = false }
    private val lock = Any()

    @Volatile
    private var cache: Map<String, String>? = null

    override fun trustedFingerprint(endpoint: String): String? = synchronized(lock) { current()[endpoint] }

    override fun trust(endpoint: String, fingerprint: String) {
        synchronized(lock) {
            val known = current()
            if (known[endpoint] == fingerprint) return
            persist(known + (endpoint to fingerprint))
        }
        ArgosLog.info(ArgosLog.TAG_HOST_KEY, "Huella confiada para $endpoint")
    }

    override fun forget(endpoint: String) {
        synchronized(lock) {
            val known = current()
            if (endpoint !in known) return
            persist(known - endpoint)
        }
        ArgosLog.info(ArgosLog.TAG_HOST_KEY, "Huella olvidada para $endpoint")
    }

    /** Llamar con [lock] tomado. */
    private fun current(): Map<String, String> = cache ?: load().also { cache = it }

    /** Llamar con [lock] tomado. */
    private fun persist(updated: Map<String, String>) {
        try {
            AtomicFiles.write(file, json.encodeToString(serializer, updated).encodeToByteArray())
            cache = updated
        } catch (error: IOException) {
            ArgosLog.error(ArgosLog.TAG_HOST_KEY, "No se pudo guardar ${file.name}", error)
            throw error
        }
    }

    private fun load(): Map<String, String> {
        if (!file.exists()) return emptyMap()
        return try {
            json.decodeFromString(serializer, file.readText())
        } catch (error: SerializationException) {
            ArgosLog.error(ArgosLog.TAG_HOST_KEY, "${file.name} no es válido; se ignora", error)
            emptyMap()
        } catch (error: IOException) {
            ArgosLog.error(ArgosLog.TAG_HOST_KEY, "No se pudo leer ${file.name}", error)
            emptyMap()
        }
    }
}
