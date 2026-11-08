package com.iaportafolio.argos.ui.terminal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.PTYSize
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.TerminalControlEvent
import com.iaportafolio.argos.core.TerminalStreaming
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.data.TerminalSettingsStore
import com.iaportafolio.argos.ui.common.UiText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield

/**
 * Terminal en vivo de UNA sesión tmux (port de `TouchTerminalController` de iOS).
 *
 * Ciclo de vida con un único [state]: conectando → conectado → desconectado (con reintento
 * automático y backoff, o «Reconectar») / sesión terminada. Como en iOS, al pasar a segundo
 * plano ([onStop]) hace detach (cancela el attach: tmux desengancha el cliente y la sesión
 * sigue viva) y al volver ([onStart]) reengancha; tmux repinta la pantalla tal como estaba.
 *
 * La salida del PTY llega por un canal acotado (si la UI va por detrás, el lector SSH espera:
 * contrapresión real) y se vuelca al emulador en lotes desde el hilo principal.
 */
@OptIn(FlowPreview::class)
class TerminalViewModel<S : TerminalSink>(
    private val serverId: String,
    private val sessionName: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val settingsStore: TerminalSettingsStore,
    /** Emulador; sobrevive a los cambios de configuración (rotación) junto con el ViewModel. */
    val screen: S,
    private val io: CoroutineDispatcher,
    private val policy: ReconnectPolicy = ReconnectPolicy(),
) : ViewModel() {

    private val mutableState = MutableStateFlow(
        TerminalUiState(
            sessionName = sessionName,
            serverName = repository.server(serverId)?.name.orEmpty(),
            settings = settingsStore.settings.value,
        ),
    )
    val state: StateFlow<TerminalUiState> = mutableState.asStateFlow()

    /** Último tamaño (columnas x filas) que midió la vista; `null` hasta la primera medición. */
    private val viewSize = MutableStateFlow<PTYSize.Dimensions?>(null)

    private var connectJob: Job? = null

    /** Canal de control del attach en curso (`null` si no hay ninguno abierto). */
    private var control: Channel<TerminalControlEvent>? = null

    /** Tamaño que conoce el PTY remoto del attach en curso (evita `window-change` repetidos). */
    private var remoteSize: PTYSize.Dimensions? = null

    /** ¿Ya se volcó algo al emulador? Entonces hay que reiniciarlo antes de reenganchar. */
    private var screenDirty = false

    init {
        screen.setResponder(::sendInput)
        viewModelScope.launch {
            settingsStore.settings.collect { settings -> mutableState.update { it.copy(settings = settings) } }
        }
        viewModelScope.launch {
            repository.servers.collect { servers ->
                servers.firstOrNull { it.id == serverId }?.let { server ->
                    mutableState.update { it.copy(serverName = server.name) }
                }
            }
        }
        viewModelScope.launch {
            viewSize.filterNotNull().debounce(policy.resizeDebounceMillis).collect(::sendResize)
        }
    }

    // MARK: - Ciclo de vida

    /** La pantalla pasa a primer plano (ON_START): engancha si no hay attach vivo. */
    fun onStart() {
        if (connectJob?.isActive == true) return
        if (state.value.status == TerminalStatus.SessionEnded) return
        connect()
    }

    /** La pantalla pasa a segundo plano (ON_STOP) o se cierra: detach (no kill). */
    fun onStop() {
        connectJob?.cancel()
        connectJob = null
    }

    /** «Reconectar»: intento nuevo desde cero (reinicia la cuenta de reintentos). */
    fun reconnect() = connect()

    private fun connect() {
        val previous = connectJob
        previous?.cancel()
        connectJob = viewModelScope.launch {
            // El canal anterior debe cerrarse antes de abrir otro (un solo cliente tmux nuestro).
            previous?.cancelAndJoin()
            runAttachLoop()
        }
    }

    private suspend fun runAttachLoop() {
        var attempt = 0
        while (true) {
            setStatus(TerminalStatus.Connecting(attempt))
            val outcome = attachOnce()
            val error = outcome.error
            if (error == null) {
                setStatus(TerminalStatus.SessionEnded)
                return
            }
            // Si llegó a conectar, la caída es nueva: la cuenta de reintentos vuelve a empezar.
            if (outcome.connected) attempt = 0
            val message = failureMessage(error)
            if (!policy.isRetryable(error) || attempt >= policy.maxAttempts) {
                setStatus(TerminalStatus.Disconnected(message, retryInSeconds = null))
                return
            }
            val wait = policy.delayFor(attempt)
            setStatus(TerminalStatus.Disconnected(message, retryInSeconds = ((wait + MILLIS_PER_SECOND - 1) / MILLIS_PER_SECOND).toInt()))
            delay(wait)
            attempt++
        }
    }

    private class AttachOutcome(val error: Exception?, val connected: Boolean)

    /** Un attach completo. Normal = EOF (detach desde tmux / sesión terminada). */
    private suspend fun attachOnce(): AttachOutcome {
        var connected = false
        var server: Server? = null
        return try {
            val target = repository.server(serverId) ?: throw TerminalServerMissingException()
            server = target
            val streaming = terminalStreaming(target)
            val size = initialSize()
            if (screenDirty) screen.reset()
            screenDirty = false
            runChannel(streaming, size) {
                screenDirty = true
                if (!connected) {
                    connected = true
                    setStatus(TerminalStatus.Connected)
                }
            }
            AttachOutcome(null, connected)
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.warn(ArgosLog.TAG_TERMINAL, "Terminal de «$sessionName» en ${server?.endpoint ?: serverId} caído", error)
            AttachOutcome(error, connected)
        }
    }

    private suspend fun terminalStreaming(server: Server): TerminalStreaming =
        services.service(server) as? TerminalStreaming ?: throw TerminalStreamingUnavailableException()

    /** Tamaño inicial del PTY: espera (poco) a la primera medición de la vista. */
    private suspend fun initialSize(): PTYSize.Dimensions {
        val measured = viewSize.value ?: withTimeoutOrNull(policy.initialSizeWaitMillis) { viewSize.filterNotNull().first() }
        return PTYSize.initial(measured?.cols ?: 0, measured?.rows ?: 0)
    }

    private suspend fun runChannel(streaming: TerminalStreaming, size: PTYSize.Dimensions, onOutput: () -> Unit) {
        val channel = Channel<TerminalControlEvent>(Channel.UNLIMITED)
        val output = Channel<ByteArray>(OUTPUT_CAPACITY)
        control = channel
        remoteSize = size
        try {
            coroutineScope {
                launch { drain(output, onOutput) }
                try {
                    withContext(io) {
                        // Copia defensiva: el contrato no garantiza que el bloque no se reutilice.
                        streaming.attachTerminal(sessionName, size.cols, size.rows, channel.receiveAsFlow()) { bytes ->
                            output.send(bytes.copyOf())
                        }
                    }
                } finally {
                    output.close()
                }
            }
        } finally {
            channel.close()
            if (control === channel) {
                control = null
                remoteSize = null
            }
        }
    }

    /** Vuelca la salida al emulador en lotes (cede el hilo entre lotes para poder pintar). */
    private suspend fun drain(output: ReceiveChannel<ByteArray>, onOutput: () -> Unit) {
        for (first in output) {
            val batch = mutableListOf(first)
            var bytes = first.size
            while (bytes < MAX_BATCH_BYTES) {
                val next = output.tryReceive().getOrNull() ?: break
                batch += next
                bytes += next.size
            }
            screen.feed(batch)
            onOutput()
            yield()
        }
    }

    private fun failureMessage(error: Exception): UiText = when (error) {
        is TerminalServerMissingException -> UiText.res(R.string.terminal_server_missing)
        is TerminalStreamingUnavailableException -> UiText.res(R.string.terminal_unsupported)
        else -> UiText.Plain(error.userMessage)
    }

    private fun setStatus(status: TerminalStatus) = mutableState.update { it.copy(status = status) }

    // MARK: - Tamaño

    /** La vista midió [cols]x[rows] (layout, rotación, teclado). El PTY se avisa con debounce. */
    fun onViewResized(cols: Int, rows: Int) {
        viewSize.value = PTYSize.Dimensions(cols, rows)
    }

    private fun sendResize(size: PTYSize.Dimensions) {
        val channel = control ?: return
        if (!PTYSize.isUsable(size.cols, size.rows) || size == remoteSize) return
        if (channel.trySend(TerminalControlEvent.Resize(size.cols, size.rows)).isSuccess) remoteSize = size
    }

    // MARK: - Entrada

    /** Bytes al PTY (descarta si no hay attach abierto: no se teclea «a ciegas»). */
    fun sendInput(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        control?.trySend(TerminalControlEvent.Input(bytes))
    }

    /** Texto del teclado del sistema (IME), con los modificadores pegajosos. */
    fun typeText(text: CharSequence) {
        if (text.isEmpty()) return
        val encoded = TerminalKeyEncoder.text(text, state.value.modifiers)
        mutableState.update { it.copy(modifiers = encoded.modifiers) }
        sendInput(encoded.bytes)
    }

    /** Tecla de la fila extra (Ctrl/Alt cambian el modificador pegajoso). */
    fun pressExtraKey(key: ExtraKey) {
        val encoded = TerminalKeyEncoder.key(key, state.value.modifiers, screen.cursorKeysApplicationMode)
        mutableState.update { it.copy(modifiers = encoded.modifiers) }
        sendInput(encoded.bytes)
    }

    /** Carácter de un teclado físico; se combinan sus Ctrl/Alt con los pegajosos. */
    fun typeHardwareCodePoint(codePoint: Int, ctrl: Boolean, alt: Boolean) {
        val modifiers = state.value.modifiers
        val bytes = TerminalKeyEncoder.codePoint(codePoint, ctrl || modifiers.ctrlActive, alt || modifiers.altActive)
        mutableState.update { it.copy(modifiers = modifiers.consumed()) }
        sendInput(bytes)
    }

    /**
     * Secuencia ya codificada de una tecla especial de un teclado físico (la vista ya aplicó
     * los modificadores pegajosos al calcularla): solo se consumen.
     */
    fun sendKeySequence(sequence: String) {
        mutableState.update { it.copy(modifiers = it.modifiers.consumed()) }
        sendInput(sequence.toByteArray(Charsets.UTF_8))
    }

    /** Pega texto (portapapeles) con «bracketed paste» si la app remota lo pidió. */
    fun paste(text: String) {
        if (text.isNotEmpty()) screen.paste(text)
    }

    // MARK: - Ajustes

    fun setFontSize(sp: Int) = settingsStore.setFontSize(sp)

    fun setKeepScreenOn(enabled: Boolean) = settingsStore.setKeepScreenOn(enabled)

    private companion object {
        /** Bloques de salida en vuelo antes de frenar al lector SSH. */
        const val OUTPUT_CAPACITY = 64
        /** Tope de bytes por lote volcado al emulador entre dos repintados. */
        const val MAX_BATCH_BYTES = 128 * 1024
        const val MILLIS_PER_SECOND = 1_000L
    }
}
