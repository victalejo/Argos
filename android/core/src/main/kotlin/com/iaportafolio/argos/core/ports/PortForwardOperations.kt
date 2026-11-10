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
