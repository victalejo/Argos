package com.iaportafolio.argos.ui.doctor

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.doctor.DiagnosticAppInfo
import com.iaportafolio.argos.core.doctor.DiagnosticInput
import com.iaportafolio.argos.core.doctor.DiagnosticLogExcerpt
import com.iaportafolio.argos.core.doctor.DiagnosticRedactor
import com.iaportafolio.argos.core.doctor.DiagnosticReport
import com.iaportafolio.argos.core.doctor.DoctorCheckID
import com.iaportafolio.argos.core.doctor.DoctorEvaluator
import com.iaportafolio.argos.core.doctor.DoctorFacts
import com.iaportafolio.argos.core.doctor.DoctorFix
import com.iaportafolio.argos.core.doctor.DoctorResult
import com.iaportafolio.argos.core.doctor.DoctorScript
import com.iaportafolio.argos.core.ports.PortForwardServerFiles
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.files.FileServerMissingException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Duration
import java.time.Instant

sealed interface DoctorLoad {
    data object Loading : DoctorLoad

    data class Loaded(val result: DoctorResult) : DoctorLoad

    data class Failed(val message: String) : DoctorLoad
}

data class DoctorUiState(
    val serverName: String = "",
    val load: DoctorLoad = DoctorLoad.Loading,
    /** «Volver a comprobar» en curso (el resultado anterior sigue a la vista). */
    val isRunning: Boolean = false,
    /** Arreglo de un toque en curso (su botón se deshabilita). */
    val fixing: DoctorCheckID? = null,
    /** Fallo del último arreglo o de la última comprobación con resultado previo. */
    val fixError: String? = null,
    /** Incluir nombres, hosts, usuarios e IPs en «Copiar diagnóstico» (los secretos nunca). */
    val includePersonalData: Boolean = false,
) {
    val result: DoctorResult? get() = (load as? DoctorLoad.Loaded)?.result
}

/** La salida no trae `done=1`: el script se cortó por el camino. */
class DoctorIncompleteOutputException : Exception(
    "El servidor no devolvió una comprobación completa. Vuelve a intentarlo; si se repite, revisa que el " +
        "servidor tenga `sh` y responda con normalidad.",
)

/**
 * Doctor del servidor (port de `ArgosCore/Doctor/DoctorModel.swift`): UNA comprobación remota de solo
 * lectura ([DoctorScript]), evaluada con [DoctorEvaluator], y arreglos de un toque solo para lo que
 * Android ya sabe hacer (hooks de Claude, skill de puertos); el resto son comandos para copiar.
 * También compone «Copiar diagnóstico» ([report]).
 */
class DoctorViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
    private val appInfo: DiagnosticAppInfo,
    private val now: () -> Instant = Instant::now,
) : ViewModel() {

    private val mutableState = MutableStateFlow(DoctorUiState(serverName = repository.server(serverId)?.name.orEmpty()))
    val state: StateFlow<DoctorUiState> = mutableState.asStateFlow()

    init {
        run()
    }

    /** Una pasada completa. Con un resultado previo, se conserva en pantalla hasta que llegue el nuevo. */
    fun run() {
        if (state.value.isRunning) return
        mutableState.update { it.copy(isRunning = true) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "Doctor de $serverId fallido") { check() }
                .onSuccess { result -> mutableState.update { it.copy(load = DoctorLoad.Loaded(result)) } }
                .onFailure { error ->
                    mutableState.update { state ->
                        if (state.result != null) state.copy(fixError = error.userMessage) else state.copy(load = DoctorLoad.Failed(error.userMessage))
                    }
                }
            mutableState.update { it.copy(isRunning = false) }
        }
    }

    private suspend fun check(): DoctorResult {
        val ssh = service()
        val started = now()
        val output = withContext(io) { ssh.runAgentScript(DoctorScript.command) }
        val finished = now()
        val facts = DoctorFacts.parse(output)
        if (!facts.isComplete) throw DoctorIncompleteOutputException()
        // Hora del dispositivo en mitad de la consulta: compensa la latencia de ida y vuelta.
        val midpoint = started.plus(Duration.between(started, finished).dividedBy(2))
        val context = DoctorEvaluator.Context(midpoint, hooksUpToDate(ssh, facts))
        return DoctorResult(DoctorEvaluator.evaluate(facts, context), finished)
    }

    /** Solo se consulta si hay hooks de Argos: comparar con la versión actual cuesta una lectura. */
    private suspend fun hooksUpToDate(ssh: SSHServicing, facts: DoctorFacts): Boolean? {
        val count = facts["hooks.marker"]?.toIntOrNull() ?: return null
        if (count <= 0) return null
        return try {
            withContext(io) { ssh.claudeHooksInstalled() }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.warn(ArgosLog.TAG_SSH, "Doctor: no se pudo verificar los hooks de $serverId", error)
            null
        }
    }

    /** Aplica un arreglo de un toque y vuelve a comprobar. Los comandos para copiar no pasan por aquí. */
    fun apply(fix: DoctorFix, id: DoctorCheckID) {
        if (state.value.fixing != null || fix is DoctorFix.CopyCommand) return
        mutableState.update { it.copy(fixing = id, fixError = null) }
        viewModelScope.launch {
            val applied = logFailures(ArgosLog.TAG_SSH, "Arreglo del Doctor ${id.name} fallido en $serverId") {
                val ssh = service()
                withContext(io) {
                    when (fix) {
                        is DoctorFix.InstallClaudeHooks -> ssh.installClaudeHooks()
                        is DoctorFix.InstallPortsSkill -> ssh.runAgentScript(PortForwardServerFiles.installCommand)
                        is DoctorFix.CopyCommand -> Unit
                    }
                }
            }
            mutableState.update { it.copy(fixing = null, fixError = applied.exceptionOrNull()?.userMessage) }
            if (applied.isSuccess) run()
        }
    }

    fun fixErrorShown() = mutableState.update { it.copy(fixError = null) }

    fun setIncludePersonalData(include: Boolean) = mutableState.update { it.copy(includePersonalData = include) }

    /**
     * «Copiar diagnóstico»: versión, dispositivo y el Doctor, con la MISMA redacción que Swift.
     * Android no guarda un registro propio de la app: el informe lo dice.
     */
    fun report(): String {
        val current = state.value
        val known = repository.servers.value.map { DiagnosticRedactor.KnownServer(it.name, it.host, it.username) }
        val input = DiagnosticInput(
            app = appInfo,
            generatedAt = now(),
            serverName = current.serverName.ifEmpty { null },
            doctor = current.result,
            log = DiagnosticLogExcerpt.Unavailable(DiagnosticReport.NO_APP_LOG_REASON),
        )
        return DiagnosticReport.compose(input, DiagnosticRedactor(known, current.includePersonalData))
    }

    private suspend fun service(): SSHServicing {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.service(server)
    }
}
