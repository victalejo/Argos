package com.iaportafolio.argos.background

import com.iaportafolio.argos.data.ArgosLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Un terminal adjunto, visto desde el servicio. */
interface ActiveTerminal {
    /** «Desconectar todo» o la app cerrada desde recientes: detach, la sesión de tmux sigue viva. */
    fun disconnectFromBackground()

    /** El servicio cayó: si este terminal está en segundo plano, debe hacer detach. */
    fun onKeepAliveLost()
}

/** Lo que necesita un terminal para sobrevivir al segundo plano. */
interface TerminalKeepAlive {
    /** ¿Sigue vivo el proceso si la app pasa a segundo plano? (ajuste activo y servicio arrancado). */
    val keepsAliveInBackground: Boolean

    /** Idempotente. Llamar con la app en primer plano: si hace falta, arranca el servicio. */
    fun register(terminal: ActiveTerminal)

    /** Idempotente. */
    fun unregister(terminal: ActiveTerminal)

    /** Sin servicio: al pasar a segundo plano se hace detach (el login de Claude y los tests). */
    object None : TerminalKeepAlive {
        override val keepsAliveInBackground: Boolean = false
        override fun register(terminal: ActiveTerminal) = Unit
        override fun unregister(terminal: ActiveTerminal) = Unit
    }
}

/** Arranca el servicio en primer plano; aislado para poder probar el registro en la JVM. */
fun interface TerminalKeepAliveHost {
    /** `false` si el sistema no lo permite. El servicio se para solo al quedarse sin terminales. */
    fun start(): Boolean
}

/**
 * Terminales adjuntos y túneles de puertos de todo el proceso: lo que mantiene el servicio en
 * primer plano. Arranca el servicio con el primero, mientras la app está en primer plano (Android
 * 12+ lo prohíbe desde segundo plano). No lo para: el servicio observa [count] y [tunnelCount] y
 * termina solo, porque `stopService` antes de su `startForeground` hace caer la app.
 */
class ActiveTerminalRegistry(
    private val host: TerminalKeepAliveHost,
    private val isEnabled: () -> Boolean,
) : TerminalKeepAlive {

    private val lock = Any()
    private var terminals: Set<ActiveTerminal> = emptySet()
    private var tunnels: Map<String, Int> = emptyMap()
    private var serviceRunning = false
    private val mutableCount = MutableStateFlow(0)
    private val mutableTunnelCount = MutableStateFlow(0)

    /** Terminales adjuntos; la notificación del servicio lo muestra. */
    val count: StateFlow<Int> = mutableCount.asStateFlow()

    /** Túneles de puertos abiertos (todos los servidores); también salen en la notificación. */
    val tunnelCount: StateFlow<Int> = mutableTunnelCount.asStateFlow()

    override val keepsAliveInBackground: Boolean
        get() = synchronized(lock) { serviceRunning } && isEnabled()

    /** ¿Está (o debería estar) el servicio en marcha? */
    val isServiceRunning: Boolean get() = synchronized(lock) { serviceRunning }

    override fun register(terminal: ActiveTerminal) {
        val mustStart = synchronized(lock) {
            terminals = terminals + terminal
            mutableCount.value = terminals.size
            !serviceRunning && isEnabled()
        }
        if (mustStart) start()
    }

    override fun unregister(terminal: ActiveTerminal) {
        synchronized(lock) {
            terminals = terminals - terminal
            mutableCount.value = terminals.size
            if (isIdle()) serviceRunning = false
        }
    }

    /**
     * Túneles abiertos ahora en [serverId] (0 = ninguno). Si es el primero del proceso, arranca el
     * servicio: llamar con la app en primer plano al abrir un túnel.
     */
    fun setTunnels(serverId: String, count: Int) {
        val mustStart = synchronized(lock) {
            tunnels = if (count > 0) tunnels + (serverId to count) else tunnels - serverId
            mutableTunnelCount.value = tunnels.values.sum()
            if (isIdle()) serviceRunning = false
            count > 0 && !serviceRunning && isEnabled()
        }
        if (mustStart) start()
    }

    /** Servidores con algún túnel abierto. */
    fun tunnelServers(): Set<String> = synchronized(lock) { tunnels.keys }

    /** «Desconectar todo» (solo los terminales; los túneles los cierra quien los conoce). */
    fun disconnectAll() = snapshot().forEach { it.disconnectFromBackground() }

    /** El servicio no pudo pasar a primer plano o el sistema lo destruyó. */
    fun serviceLost() {
        synchronized(lock) { serviceRunning = false }
        snapshot().forEach { it.onKeepAliveLost() }
    }

    private fun start() {
        val started = host.start()
        synchronized(lock) { serviceRunning = started && !isIdle() }
        if (!started) ArgosLog.warn(ArgosLog.TAG_TERMINAL, "Sin servicio: el terminal hará detach en segundo plano")
    }

    /** Llamar con [lock] tomado. */
    private fun isIdle(): Boolean = terminals.isEmpty() && tunnels.isEmpty()

    private fun snapshot(): Set<ActiveTerminal> = synchronized(lock) { terminals }
}
