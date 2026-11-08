package com.iaportafolio.argos.ui.importer

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.keys.ServerTransfer
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerImporter
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Duration
import java.time.Instant

/** Lo que se enseña para confirmar un servidor del QR. Sin secretos: la semilla no viaja aquí. */
data class ImportPreview(
    val name: String,
    val username: String,
    val host: String,
    val port: Int,
    /** Huella que trae el QR; `null` = se confiará en la primera conexión. */
    val hostKeyFingerprint: String?,
    /** Ya hay un servidor con el mismo host, puerto y usuario: se añadirá otro. */
    val isDuplicate: Boolean,
    /** La huella del QR no coincide con la que ya confía este dispositivo: no se puede añadir. */
    val conflictsWithTrustedHostKey: Boolean,
) {
    /** `usuario@host` y el puerto solo si no es el 22 (como iOS). */
    val address: String get() = "$username@$host" + if (port == Server.DEFAULT_PORT) "" else ":$port"
}

/**
 * Estado de «Añadir desde el Mac». [linkText] puede llevar la semilla (el enlace pegado): se
 * vacía en cuanto se acepta y [toString] lo oculta.
 */
data class ImportServerState(
    val linkText: String = "",
    /** Por qué no se aceptó el último código o enlace (escaneado, pegado o deep link). */
    val inputError: UiText? = null,
    val preview: ImportPreview? = null,
    val isImporting: Boolean = false,
    val saveError: UiText? = null,
    /** Importado con éxito: la navegación vuelve a la lista y abre este servidor. */
    val importedServerId: String? = null,
) {
    val canImport: Boolean get() = preview != null && !preview.conflictsWithTrustedHostKey && !isImporting

    override fun toString(): String =
        "ImportServerState(linkText=<${linkText.length} caracteres>, inputError=$inputError, preview=$preview, " +
            "isImporting=$isImporting, saveError=$saveError, importedServerId=$importedServerId)"
}

/** Acciones de la pantalla (interfaz para poder previsualizarla sin ViewModel). */
interface ImportServerActions {
    fun onLinkTextChange(value: String)
    fun submitLink()
    fun onScanned(text: String)
    fun scanAgain()
    fun confirmImport()
}

/**
 * Añadir un servidor desde el QR del Mac (equivale a `ImportServerSheet` de iOS). Acepta el
 * código escaneado, el enlace pegado o un deep link, y SIEMPRE pide confirmación antes de
 * guardar. El [ServerTransfer] (con la semilla) vive solo aquí, fuera del estado, y se suelta
 * al importar o descartar.
 */
class ImportServerViewModel(
    private val repository: ServerRepository,
    private val importer: ServerImporter,
    private val io: CoroutineDispatcher,
    private val clock: () -> Instant = Instant::now,
) : ViewModel(), ImportServerActions {

    private val mutableState = MutableStateFlow(ImportServerState())
    val state: StateFlow<ImportServerState> = mutableState.asStateFlow()

    private var transfer: ServerTransfer? = null
    /** Último texto escaneado: la cámara lee el mismo QR muchas veces por segundo. */
    private var lastScanned: String? = null
    private var acceptJob: Job? = null

    override fun onLinkTextChange(value: String) {
        // Un poco más que el tope: basta para avisar de «demasiado largo» sin guardar megas.
        mutableState.update { it.copy(linkText = value.take(ImportLink.MAX_LENGTH + 1), inputError = null) }
    }

    override fun submitLink() = accept(state.value.linkText)

    override fun onScanned(text: String) {
        if (state.value.preview != null || text == lastScanned) return
        lastScanned = text
        accept(text)
    }

    /** Enlace recibido por deep link (ya filtrado por [ImportLink.fromIntent]). */
    fun onDeepLink(text: String) = accept(text)

    override fun scanAgain() {
        if (state.value.isImporting) return
        acceptJob?.cancel()
        transfer = null
        lastScanned = null
        mutableState.value = ImportServerState()
    }

    /** La navegación ya atendió [ImportServerState.importedServerId]. */
    fun importHandled() = mutableState.update { it.copy(importedServerId = null) }

    private fun accept(raw: String) {
        if (state.value.isImporting) return
        val text = raw.trim()
        val rejection = when {
            text.isEmpty() -> UiText.res(R.string.import_error_empty)
            ImportLink.isTooLong(text) -> UiText.res(R.string.import_error_too_long)
            else -> null
        }
        if (rejection != null) {
            mutableState.update { it.copy(inputError = rejection) }
            return
        }
        acceptJob?.cancel()
        acceptJob = viewModelScope.launch {
            val decoded = try {
                ServerTransfer.decode(text, clock())
            } catch (error: ServerTransfer.DecodeException) {
                ArgosLog.warn(ArgosLog.TAG_UI, "Código de importación rechazado: ${error.error.name}")
                mutableState.update { it.copy(inputError = error.error.toUiText()) }
                return@launch
            }
            logFailures(ArgosLog.TAG_HOST_KEY, "No se pudo leer la huella confiada") {
                withContext(io) { importer.trustedFingerprint(decoded) }
            }.onSuccess { trusted ->
                transfer = decoded
                mutableState.value = ImportServerState(preview = preview(decoded, trusted))
            }.onFailure { error -> mutableState.update { it.copy(inputError = error.toUiText()) } }
        }
    }

    private fun preview(transfer: ServerTransfer, trusted: String?) = ImportPreview(
        name = transfer.name,
        username = transfer.username,
        host = transfer.host,
        port = transfer.port,
        hostKeyFingerprint = transfer.hostKeyFingerprint,
        isDuplicate = repository.servers.value.any {
            it.host == transfer.host && it.port == transfer.port && it.username == transfer.username
        },
        conflictsWithTrustedHostKey = transfer.conflictsWithTrustedHostKey(trusted),
    )

    override fun confirmImport() {
        val current = state.value
        val pending = transfer
        if (pending == null || !current.canImport) return
        // El código caduca a los 5 minutos también mientras se lee la confirmación.
        if (Duration.between(pending.createdAt, clock()) > ServerTransfer.LIFETIME) {
            transfer = null
            mutableState.value = ImportServerState(inputError = ServerTransfer.DecodeError.EXPIRED.toUiText())
            return
        }
        mutableState.value = current.copy(isImporting = true, saveError = null)
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_STORE, "No se pudo añadir el servidor del QR") {
                withContext(io) { importer.import(pending) }
            }.onSuccess { server ->
                transfer = null
                mutableState.value = ImportServerState(importedServerId = server.id)
            }.onFailure { error ->
                mutableState.update { state ->
                    if (error is ServerTransfer.HostKeyConflictException) {
                        state.copy(isImporting = false, preview = state.preview?.copy(conflictsWithTrustedHostKey = true))
                    } else {
                        state.copy(isImporting = false, saveError = UiText.res(R.string.import_save_failed, error.userMessage))
                    }
                }
            }
        }
    }
}

/** Textos de Android para cada motivo de rechazo (los de `core` hablan del iPhone). */
internal fun ServerTransfer.DecodeError.toUiText(): UiText = UiText.res(
    when (this) {
        ServerTransfer.DecodeError.NOT_ARGOS_CODE -> R.string.import_error_not_argos
        ServerTransfer.DecodeError.MALFORMED -> R.string.import_error_malformed
        ServerTransfer.DecodeError.UNSUPPORTED_VERSION -> R.string.import_error_version
        ServerTransfer.DecodeError.EXPIRED -> R.string.import_error_expired
        ServerTransfer.DecodeError.INVALID_DATA -> R.string.import_error_invalid
    },
)
