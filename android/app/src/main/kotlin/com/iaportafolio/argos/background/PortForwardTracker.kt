package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.ports.ActivePortForward
import com.iaportafolio.argos.core.ports.PortForwardOperations
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** Quien abre, cierra o lista túneles cuenta cuántos quedan (para el servicio en primer plano). */
fun interface PortForwardReporter {
    fun report(serverId: String, forwards: List<ActivePortForward>)

    companion object {
        /** Sin servicio (tests, previsualizaciones). */
        val None = PortForwardReporter { _, _ -> }
    }
}

/**
 * Túneles de puertos vistos desde el servicio en primer plano: los túneles viven en el
 * `SSHServicing` compartido de cada servidor (`ServiceHub`), aquí solo se cuentan para que el
 * proceso siga vivo mientras el navegador los usa, y se cierran desde la notificación.
 *
 * Nunca abre una conexión: solo mira las que ya están abiertas ([ServiceProvider.cached]). Si la
 * conexión de un servidor se cerró, sus túneles murieron con ella.
 */
class PortForwardTracker(
    private val registry: ActiveTerminalRegistry,
    private val servers: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
) : PortForwardReporter {

    override fun report(serverId: String, forwards: List<ActivePortForward>) = registry.setTunnels(serverId, forwards.size)

    /** El `ServiceHub` cerró la conexión del servidor: sus túneles ya no existen. */
    fun serverDisconnected(serverId: String) = registry.setTunnels(serverId, 0)

    /**
     * Relee cuántos túneles siguen abiertos (el cierre automático por inactividad del módulo `ssh`
     * los cierra sin avisar). Local salvo que un túnel caído toque reabrirse.
     */
    suspend fun refreshAll() {
        for (serverId in registry.tunnelServers()) {
            val ops = operations(serverId)
            if (ops == null) {
                registry.setTunnels(serverId, 0)
                continue
            }
            try {
                report(serverId, withContext(io) { ops.activePortForwards() })
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Exception) {
                ArgosLog.warn(ArgosLog.TAG_SSH, "No se pudieron releer los túneles de $serverId", error)
            }
        }
    }

    /** «Cerrar todo» de la notificación (o la app cerrada desde recientes). */
    suspend fun closeAll() {
        for (serverId in registry.tunnelServers()) {
            try {
                operations(serverId)?.let { ops ->
                    withContext(io) { ops.activePortForwards().forEach { ops.stopPortForward(it.id) } }
                }
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Exception) {
                ArgosLog.warn(ArgosLog.TAG_SSH, "No se pudieron cerrar los túneles de $serverId", error)
            } finally {
                registry.setTunnels(serverId, 0)
            }
        }
    }

    private fun operations(serverId: String): PortForwardOperations? {
        val server = servers.server(serverId) ?: return null
        return services.cached(server) as? PortForwardOperations
    }
}
