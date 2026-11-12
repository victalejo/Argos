package com.iaportafolio.argos.core.ports

/**
 * Un túnel activo `localhost:<localPort>` del dispositivo → `targetHost:remotePort` del servidor
 * (como `ssh -L`). Port de `ActivePortForward` de Apple.
 */
data class ActivePortForward(
    val id: String,
    val remotePort: Int,
    val targetHost: String,
    val localPort: Int,
    /** Su conexión se cayó y aún no se ha podido reabrir (se reintenta sola). */
    val isReconnecting: Boolean = false,
) {
    val localUrl: String get() = "http://localhost:$localPort"
    val localAddress: String get() = "localhost:$localPort"
}

/**
 * Reenvío de puertos del servidor al dispositivo (port de `ArgosCore/PortForwarding/`). Separado
 * de `SSHServicing` igual que `GitOperations`. Los túneles viven en el servicio (no en la
 * pantalla): cerrar la pantalla no los corta.
 */
interface PortForwardOperations {
    /** Puertos TCP en escucha en el servidor. */
    suspend fun listeningPorts(): List<ListeningPort>

    /**
     * Abre un túnel en 127.0.0.1 del dispositivo (nunca en la red local). Intenta usar
     * [preferredLocalPort]; si está ocupado, uno libre.
     */
    suspend fun startPortForward(remotePort: Int, targetHost: String, preferredLocalPort: Int): ActivePortForward

    suspend fun stopPortForward(id: String)

    /** Túneles activos (reabre los que perdieron la conexión). */
    suspend fun activePortForwards(): List<ActivePortForward>

    /** Solicitudes de Claude para abrir un puerto (`argos-ports open`), pendientes de confirmar. */
    suspend fun pendingPortForwardRequests(): List<PortForwardRequest>

    /** Retira una solicitud (aceptada o rechazada). */
    suspend fun dismissPortForwardRequest(port: Int)
}

/** Una solicitud pendiente de Claude (port de `PortForwardRequest.swift`). */
data class PortForwardRequest(val port: Int, val note: String, val ageSeconds: Int)

object PortForwardRequestParser {
    /** Máximo de caracteres de la nota que se muestran. */
    const val NOTE_LIMIT = 200

    /**
     * Primera línea numérica = hora del servidor; después `puerto<TAB>creada<TAB>nota`. Ignora
     * puertos inválidos y solicitudes caducadas; las más antiguas primero.
     */
    fun parse(output: String): List<PortForwardRequest> {
        var now: Long? = null
        val requests = mutableListOf<Pair<Long, PortForwardRequest>>()
        for (line in output.lines().filter { it.isNotEmpty() }) {
            if (now == null) {
                now = line.trim().toLongOrNull()
                continue
            }
            val fields = line.split('\t', limit = 3)
            if (fields.size < 2) continue
            val port = fields[0].toIntOrNull()?.takeIf { it in 1..65535 } ?: continue
            val created = fields[1].trim().toLongOrNull() ?: continue
            val age = maxOf(0L, now - created)
            if (age > PortForwardServerFiles.REQUEST_MAX_AGE_SECONDS) continue
            val note = fields.getOrNull(2)?.trim()?.take(NOTE_LIMIT).orEmpty()
            requests += created to PortForwardRequest(port, note, age.toInt())
        }
        return requests.sortedBy { it.first }.map { it.second }
    }
}

/** Fallo al abrir un túnel, con un mensaje para mostrar tal cual. */
class PortForwardException(message: String) : Exception(message) {
    companion object {
        fun invalidPort(port: Int) = PortForwardException("El puerto $port no es válido (debe estar entre 1 y 65535).")
        fun alreadyForwarded(port: Int) = PortForwardException("El puerto $port ya se está reenviando.")
        fun bindFailed(detail: String) = PortForwardException("No se pudo abrir el puerto en este dispositivo: $detail")
    }
}

/** Valida un puerto escrito a mano (como `PortForwardsModel.parsePort` de Apple). */
fun parsePort(text: String): Int? = text.trim().toIntOrNull()?.takeIf { it in 1..65535 }
