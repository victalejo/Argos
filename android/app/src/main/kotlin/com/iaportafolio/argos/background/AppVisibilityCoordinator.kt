package com.iaportafolio.argos.background

import com.iaportafolio.argos.data.ArgosLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** Lo que el coordinador necesita de la conexión compartida (el `ServiceHub`). */
interface SharedConnections {
    /** Cierra las conexiones que no respondan en [timeoutMillis]. */
    suspend fun probeAll(timeoutMillis: Long): Set<String>

    suspend fun closeAll()
}

/** Plazos del coordinador (inyectables para los tests). */
data class VisibilityTimings(
    /** Avisos de agentes con la app a la vista. */
    val checkIntervalMillis: Long = 60_000,
    /** Sin servicio ni túneles, tras este tiempo en segundo plano se cierran las conexiones. */
    val closeAfterHiddenMillis: Long = 60_000,
    /** Plazo de la comprobación de las conexiones al volver (3–5 s). */
    val probeTimeoutMillis: Long = 4_000,
    /** Por debajo de esto oculta (p. ej. un diálogo del sistema) no se comprueba nada al volver. */
    val probeAfterHiddenMillis: Long = 5_000,
)

/**
 * Lo que pasa al entrar y salir de primer plano (equivale al `scenePhase` de iOS):
 * - A la vista: comprueba con plazo corto las conexiones abiertas (un NAT caducado o Doze las deja
 *   muertas y la pantalla esperaría 30–90 s), retoma el CI y revisa los agentes: todos al volver y
 *   después, cada minuto, los de los servidores con conexión abierta (sin abrir conexiones nuevas).
 * - Oculta: a los ~60 s cierra las conexiones si no hay servicio en primer plano ni túneles.
 *
 * La visibilidad la marca la Activity (app de una sola Activity) con [onAppStarted]/[onAppStopped].
 */
class AppVisibilityCoordinator(
    private val scope: CoroutineScope,
    private val connections: SharedConnections,
    /** [full] = al volver (todos los servidores); si no, solo los que tienen conexión abierta. */
    private val checkAgents: suspend (full: Boolean) -> Unit,
    private val onVisible: () -> Unit,
    /** ¿Hay servicio en primer plano o túneles? Entonces no se cierra nada al ocultarse. */
    private val isKeepingAlive: () -> Boolean,
    private val timings: VisibilityTimings = VisibilityTimings(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutableVisible = MutableStateFlow(false)
    private var hiddenAt: Long? = null

    val visible: StateFlow<Boolean> = mutableVisible.asStateFlow()

    fun start() {
        scope.launch {
            // El primer valor (falso, sin Activity aún) solo puede cerrar un hub vacío: inofensivo.
            mutableVisible.collectLatest { isVisible -> if (isVisible) whileVisible() else whileHidden() }
        }
    }

    fun onAppStarted() {
        mutableVisible.value = true
    }

    fun onAppStopped() {
        hiddenAt = clock()
        mutableVisible.value = false
    }

    private suspend fun whileVisible() {
        val hiddenFor = hiddenAt?.let { clock() - it }
        hiddenAt = null
        onVisible()
        if (hiddenFor != null && hiddenFor >= timings.probeAfterHiddenMillis) {
            val dead = connections.probeAll(timings.probeTimeoutMillis)
            if (dead.isNotEmpty()) ArgosLog.info(ArgosLog.TAG_SSH, "Al volver se descartaron ${dead.size} conexiones sin respuesta")
        }
        var full = true
        while (true) {
            checkAgents(full)
            full = false
            delay(timings.checkIntervalMillis)
        }
    }

    private suspend fun whileHidden() {
        delay(timings.closeAfterHiddenMillis)
        if (!isKeepingAlive()) connections.closeAll()
    }
}

/**
 * ¿Cambió la red por defecto de forma que las conexiones abiertas ya no sirven? (Wi-Fi → datos,
 * otra Wi-Fi, o vuelta tras perderla). Pura: recibe los identificadores de `Network`.
 */
class NetworkChangeTracker {
    private var current: Long? = null
    private var lostSinceLast = false

    /** Nueva red por defecto. `true` = hay que cerrar las conexiones abiertas. */
    @Synchronized
    fun onAvailable(network: Long): Boolean {
        val previous = current
        val changed = (previous != null && previous != network) || (previous == null && lostSinceLast)
        current = network
        lostSinceLast = false
        return changed
    }

    @Synchronized
    fun onLost(network: Long) {
        if (network == current) {
            current = null
            lostSinceLast = true
        }
    }
}
