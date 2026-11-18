package com.iaportafolio.argos.ui.monitor

import androidx.lifecycle.ViewModel
import com.iaportafolio.argos.core.monitor.ServerResourceReading
import com.iaportafolio.argos.core.monitor.ServerResourceSample
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.files.FileServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext

data class ResourceMonitorUiState(
    val serverName: String = "",
    val sample: ServerResourceSample? = null,
    /** Uso de CPU (0…1) entre las dos últimas muestras; `null` hasta tener dos. */
    val cpuUsage: Double? = null,
    /** Último fallo (la muestra anterior, si la hay, sigue a la vista). */
    val error: String? = null,
)

/**
 * Monitor de recursos del servidor (como el del Mac): carga, CPU, memoria, swap, disco, tiempo
 * encendido y los procesos que más CPU consumen, con un solo comando cada [intervalMillis] mientras
 * la pantalla está a la vista.
 */
class ResourceMonitorViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
    private val intervalMillis: Long = REFRESH_MILLIS,
) : ViewModel() {

    private val mutableState = MutableStateFlow(ResourceMonitorUiState(serverName = repository.server(serverId)?.name.orEmpty()))
    val state: StateFlow<ResourceMonitorUiState> = mutableState.asStateFlow()

    /** Lo lanza la pantalla mientras está iniciada (y lo cancela al salir). */
    suspend fun pollWhileVisible() {
        while (true) {
            refreshOnce()
            delay(intervalMillis)
        }
    }

    suspend fun refreshOnce() {
        logFailures(ArgosLog.TAG_SSH, "No se pudieron leer los recursos de $serverId") {
            val server = repository.server(serverId) ?: throw FileServerMissingException()
            val reader = services.service(server) as? ServerResourceReading ?: throw UnsupportedOperationException(UNSUPPORTED)
            withContext(io) { reader.resourceSample() }
        }.onSuccess { fresh ->
            mutableState.update { state ->
                val usage = state.sample?.let { fresh.cpu.usageSince(it.cpu) } ?: state.cpuUsage
                state.copy(sample = fresh, cpuUsage = usage, error = null)
            }
        }.onFailure { error -> mutableState.update { it.copy(error = error.userMessage) } }
    }

    companion object {
        const val REFRESH_MILLIS = 3_000L
        private const val UNSUPPORTED = "Esta conexión no admite el monitor de recursos. Actualiza Argos."
    }
}
