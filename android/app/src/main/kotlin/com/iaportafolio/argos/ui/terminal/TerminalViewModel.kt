package com.iaportafolio.argos.ui.terminal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.ActiveTerminal
import com.iaportafolio.argos.background.TerminalKeepAlive
import com.iaportafolio.argos.core.PTYSize
import com.iaportafolio.argos.core.SSHServicing
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

/** Qué ejecuta el PTY del terminal. */
sealed interface TerminalTarget {
    /** `tmux attach` a la sesión (el caso normal). */
    data object TmuxSession : TerminalTarget

    /** Un comando suelto (login de Claude); se resuelve al abrir porque puede necesitar el servidor. */
    fun interface Command : TerminalTarget {
        suspend fun resolve(service: SSHServicing): String
    }
}

/**
 * Terminal en vivo de UNA sesión tmux (port de `TouchTerminalController` de iOS).
 *
 * Ciclo de vida con un único [state]: conectando → conectado → desconectado (con reintento
 * automático y backoff, o «Reconectar») / sesión terminada. Con el servicio de [keepAlive] en
 * marcha, pasar a segundo plano ([onStop]) no toca la conexión y la salida sigue llegando al
 * emulador. Sin él, como en iOS, hace detach (cancela el attach: tmux desengancha el cliente y
 * la sesión sigue viva) y al volver ([onStart]) reengancha; tmux repinta la pantalla tal como
 * estaba. Salir de la pantalla ([onLeave]) siempre hace detach.
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
    private val target: TerminalTarget = TerminalTarget.TmuxSession,
    /** Observa la salida ya volcada al emulador (el login busca en ella su enlace). */
    private val outputTap: (List<ByteArray>) -> Unit = {},
    private val keepAlive: TerminalKeepAlive = TerminalKeepAlive.None,
) : ViewModel(), ActiveTerminal {

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

    /** Identifica el attach vigente: uno anterior que termina tarde no debe soltar el registro. */
    private var connectGeneration = 0

    /** Parado por [onStop] con la conexión viva; lo sabe [onKeepAliveLost]. */
    private var inBackground = false

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
        inBackground = false
        if (connectJob?.isActive == true) {
            // Sigue conectado sin repintar. Si el servicio no estaba, se reintenta ahora en primer plano.
            keepAlive.register(this)
            return
        }
        if (state.value.status == TerminalStatus.SessionEnded) return
        connect()
    }

    /** La app pasa a segundo plano (ON_STOP): con el servicio sigue conectado; sin él, detach (no kill). */
    fun onStop() {
        if (keepAlive.keepsAliveInBackground && connectJob?.isActive == true) {
            inBackground = true
        } else {
            detach()
        }
    }

    /** Se sale de la pantalla (con la app aún en primer plano): detach (no kill). */
    fun onLeave() = detach()

    private fun detach() {
        inBackground = false
        connectJob?.cancel()
        connectJob = null
        keepAlive.unregister(this)
    }

    /** «Desconectar todo»: detach. Si el terminal está a la vista, se ofrece reconectar. */
    override fun disconnectFromBackground() {
        detach()
        if (state.value.status != TerminalStatus.SessionEnded) {
            setStatus(TerminalStatus.Disconnected(UiText.res(R.string.terminal_disconnected_by_user), retryInSeconds = null))
        }
    }

    override fun onKeepAliveLost() {
        if (inBackground) detach()
    }

    override fun onCleared() {
        keepAlive.unregister(this)
    }

    /** «Reconectar»: intento nuevo desde cero (reinicia la cuenta de reintentos). */
    fun reconnect() = connect()

    private fun connect() {
        val previous = connectJob
        previous?.cancel()
        val generation = ++connectGeneration
        // Antes de lanzar y sin soltar el anterior: al reconectar la cuenta no pasa por cero.
        keepAlive.register(this)
        connectJob = viewModelScope.launch {
            // El canal anterior debe cerrarse antes de abrir otro (un solo cliente tmux nuestro).
            previous?.cancelAndJoin()
            try {
                runAttachLoop()
            } finally {
                // Sesión terminada o reintentos agotados: ya no hay nada que mantener vivo.
                if (generation == connectGeneration) keepAlive.unregister(this@TerminalViewModel)
            }
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
            val current = repository.server(serverId) ?: throw TerminalServerMissingException()
            server = current
            val service = services.service(current)
            val streaming = service as? TerminalStreaming ?: throw TerminalStreamingUnavailableException()
            val size = initialSize()
            if (screenDirty) screen.reset()
            screenDirty = false
            runChannel(service, streaming, size) {
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

    /** Tamaño inicial del PTY: espera (poco) a la primera medición de la vista. */
    private suspend fun initialSize(): PTYSize.Dimensions {
        val measured = viewSize.value ?: withTimeoutOrNull(policy.initialSizeWaitMillis) { viewSize.filterNotNull().first() }
        return PTYSize.initial(measured?.cols ?: 0, measured?.rows ?: 0)
    }

    private suspend fun runChannel(
        service: SSHServicing,
        streaming: TerminalStreaming,
        size: PTYSize.Dimensions,
        onOutput: () -> Unit,
    ) {
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
                        val deliver: suspend (ByteArray) -> Unit = { bytes -> output.send(bytes.copyOf()) }
                        when (target) {
                            TerminalTarget.TmuxSession ->
                                streaming.attachTerminal(sessionName, size.cols, size.rows, channel.receiveAsFlow(), deliver)
                            is TerminalTarget.Command ->
                                streaming.attachCommand(target.resolve(service), size.cols, size.rows, channel.receiveAsFlow(), deliver)
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
            outputTap(batch)
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
