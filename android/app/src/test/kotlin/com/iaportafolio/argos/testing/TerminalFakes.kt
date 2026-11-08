package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.TerminalControlEvent
import com.iaportafolio.argos.core.TerminalStreaming
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.data.TerminalSettings
import com.iaportafolio.argos.data.TerminalSettingsStore
import com.iaportafolio.argos.ui.terminal.TerminalSink
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Un `attachTerminal` en curso del doble: el test decide cuándo y cómo termina. */
class AttachCall(val session: String, val cols: Int, val rows: Int, private val output: suspend (ByteArray) -> Unit) {
    val events = mutableListOf<TerminalControlEvent>()

    /** Completar con `null` = EOF (detach desde tmux); con una excepción = caída. */
    val end = CompletableDeferred<Exception?>()
    var cancelled = false
    var closed = false

    val inputs: List<ByteArray> get() = events.filterIsInstance<TerminalControlEvent.Input>().map { it.bytes }
    val resizes: List<TerminalControlEvent.Resize> get() = events.filterIsInstance<TerminalControlEvent.Resize>()

    suspend fun emit(text: String) = output(text.toByteArray(Charsets.UTF_8))
}

/** [SSHServicing] de tmux ([FakeSSHService]) + canales PTY programables. */
class FakeTerminalService(base: FakeSSHService = FakeSSHService()) : SSHServicing by base, TerminalStreaming {
    val calls = mutableListOf<AttachCall>()

    /** Comandos abiertos con `attachCommand` (también figuran en [calls]). */
    val commands = mutableListOf<String>()

    /** Errores al ABRIR (uno por intento, en orden); vacío = el attach se abre. */
    val openErrors = ArrayDeque<Exception>()
    var openAttempts = 0

    override suspend fun attachTerminal(
        session: String,
        initialCols: Int,
        initialRows: Int,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    ): Unit = coroutineScope {
        openAttempts++
        openErrors.removeFirstOrNull()?.let { throw it }
        val call = AttachCall(session, initialCols, initialRows, output)
        calls += call
        val collector = launch { control.collect { call.events += it } }
        try {
            val error = call.end.await()
            if (error != null) throw error
        } catch (cancel: CancellationException) {
            call.cancelled = true
            throw cancel
        } finally {
            call.closed = true
            collector.cancel()
        }
    }

    override suspend fun attachCommand(
        command: String,
        initialCols: Int,
        initialRows: Int,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    ) {
        commands += command
        attachTerminal(command, initialCols, initialRows, control, output)
    }
}

/** Proveedor con un servicio cualquiera (con o sin [TerminalStreaming]). */
class SingleServiceProvider(var service: SSHServicing) : ServiceProvider {
    var error: Exception? = null

    override suspend fun service(server: Server): SSHServicing {
        error?.let { throw it }
        return service
    }

    override suspend fun invalidate(serverId: String) = Unit
}

class FakeTerminalSink : TerminalSink {
    private var responder: (ByteArray) -> Unit = {}
    val fed = StringBuilder()
    var feedBatches = 0
    var resets = 0
    val pasted = mutableListOf<String>()
    override var cursorKeysApplicationMode = false

    override fun setResponder(responder: (ByteArray) -> Unit) {
        this.responder = responder
    }

    override fun feed(chunks: List<ByteArray>) {
        feedBatches++
        chunks.forEach { fed.append(String(it, Charsets.UTF_8)) }
    }

    override fun reset() {
        resets++
        fed.clear()
    }

    override fun paste(text: String) {
        pasted += text
        responder("\u001B[200~$text\u001B[201~".toByteArray(Charsets.UTF_8))
    }

    /** Simula una respuesta del emulador (p. ej. a una petición DA). */
    fun respond(text: String) = responder(text.toByteArray(Charsets.UTF_8))
}

class InMemoryTerminalSettings(initial: TerminalSettings = TerminalSettings()) : TerminalSettingsStore {
    private val state = MutableStateFlow(initial)
    override val settings: StateFlow<TerminalSettings> = state

    override fun setFontSize(sp: Int) = state.update { it.copy(fontSizeSp = TerminalSettings.clampFontSize(sp)) }

    override fun setKeepScreenOn(enabled: Boolean) = state.update { it.copy(keepScreenOn = enabled) }
}
