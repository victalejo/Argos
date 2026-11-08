package com.iaportafolio.argos.terminal

import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.ui.terminal.TerminalSink
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient

/**
 * Puente entre el emulador de Termux y un PTY REMOTO.
 *
 * En Termux, `TerminalSession` (clase final) lanza un proceso local por JNI y lee/escribe su
 * descriptor; `TerminalView` (también final) solo sabe pintar una `TerminalSession`. Aquí no
 * hay proceso local: se usa [TerminalEmulator] directamente con un [TerminalOutput] propio
 * cuyo `write` (respuestas del emulador: DA, posición del cursor, ratón, pegar) va al PTY
 * remoto a través del responder, y la salida del PTY entra con [feed]. Lo pinta
 * [RemoteTerminalView] con el `TerminalRenderer` de Termux.
 *
 * Todo se usa desde el hilo principal (el emulador no es seguro entre hilos).
 */
class RemoteTerminalSession(transcriptRows: Int = TRANSCRIPT_ROWS) : TerminalSink {

    /** Lo que la vista quiere saber del emulador. */
    interface Listener {
        fun onScreenUpdated()
        fun onCopyToClipboard(text: String)
        fun onPasteRequested()
        fun onBell()
    }

    private var responder: (ByteArray) -> Unit = {}

    /** La vista enganchada (o `null`): se limpia al soltarla para no filtrarla. */
    var listener: Listener? = null

    private val output = object : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) {
            responder(data.copyOfRange(offset, offset + count))
        }

        override fun titleChanged(oldTitle: String?, newTitle: String?) = Unit

        override fun onCopyTextToClipboard(text: String?) {
            if (!text.isNullOrEmpty()) listener?.onCopyToClipboard(text)
        }

        override fun onPasteTextFromClipboard() {
            listener?.onPasteRequested()
        }

        override fun onBell() {
            listener?.onBell()
        }

        override fun onColorsChanged() {
            listener?.onScreenUpdated()
        }
    }

    val emulator: TerminalEmulator = TerminalEmulator(
        output,
        INITIAL_COLUMNS,
        INITIAL_ROWS,
        INITIAL_CELL_WIDTH,
        INITIAL_CELL_HEIGHT,
        transcriptRows,
        EmulatorClient,
    )

    override fun setResponder(responder: (ByteArray) -> Unit) {
        this.responder = responder
    }

    override fun feed(chunks: List<ByteArray>) {
        chunks.forEach { emulator.append(it, it.size) }
        listener?.onScreenUpdated()
    }

    /** RIS (`ESC c`): estado inicial, pantalla e historial vacíos. */
    override fun reset() {
        emulator.append(RESET_SEQUENCE, RESET_SEQUENCE.size)
        listener?.onScreenUpdated()
    }

    override fun paste(text: String) = emulator.paste(text)

    override val cursorKeysApplicationMode: Boolean get() = emulator.isCursorKeysApplicationMode

    /** Ajusta el emulador al tamaño de la vista (el PTY remoto lo avisa el ViewModel, con debounce). */
    fun resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        emulator.resize(columns, rows, cellWidthPixels, cellHeightPixels)
    }

    /**
     * Cliente que pide el emulador para registrar avisos y elegir el cursor. Los métodos de
     * `TerminalSession` no se llaman nunca: no hay sesión local.
     */
    private object EmulatorClient : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) = Unit
        override fun onTitleChanged(changedSession: TerminalSession) = Unit
        override fun onSessionFinished(finishedSession: TerminalSession) = Unit
        override fun onCopyTextToClipboard(session: TerminalSession, text: String?) = Unit
        override fun onPasteTextFromClipboard(session: TerminalSession?) = Unit
        override fun onBell(session: TerminalSession) = Unit
        override fun onColorsChanged(session: TerminalSession) = Unit
        override fun onTerminalCursorStateChange(state: Boolean) = Unit
        override fun getTerminalCursorStyle(): Int? = TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK

        // Solo se registran los errores; el resto (secuencias desconocidas…) sería ruido.
        override fun logError(tag: String?, message: String?) = ArgosLog.warn(ArgosLog.TAG_TERMINAL, "Emulador: $message")
        override fun logWarn(tag: String?, message: String?) = Unit
        override fun logInfo(tag: String?, message: String?) = Unit
        override fun logDebug(tag: String?, message: String?) = Unit
        override fun logVerbose(tag: String?, message: String?) = Unit
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) =
            ArgosLog.warn(ArgosLog.TAG_TERMINAL, "Emulador: $message", e)
        override fun logStackTrace(tag: String?, e: Exception?) = ArgosLog.warn(ArgosLog.TAG_TERMINAL, "Emulador", e)
    }

    companion object {
        /** Historial local (solo útil fuera de tmux: tmux lleva el suyo, `history-limit 50000`). */
        const val TRANSCRIPT_ROWS = 2_000
        private const val INITIAL_COLUMNS = 80
        private const val INITIAL_ROWS = 24
        private const val INITIAL_CELL_WIDTH = 12
        private const val INITIAL_CELL_HEIGHT = 24
        private val RESET_SEQUENCE = byteArrayOf(0x1B, 'c'.code.toByte())
    }
}
