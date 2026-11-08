package com.iaportafolio.argos.ui.terminal

/**
 * Lo que el [TerminalViewModel] necesita del emulador, sin depender de Termux ni de Android
 * (los tests usan un doble). Se usa SIEMPRE desde el hilo principal.
 *
 * La implementación real es [com.iaportafolio.argos.terminal.RemoteTerminalSession].
 */
interface TerminalSink {

    /** Destino de lo que el propio emulador quiere escribir en el PTY (respuestas DA, ratón, pegar). */
    fun setResponder(responder: (ByteArray) -> Unit)

    /** Procesa un lote de salida del PTY, en orden, y pide un repintado. */
    fun feed(chunks: List<ByteArray>)

    /** Vuelve al estado inicial (antes de un reattach: tmux repinta la pantalla entera). */
    fun reset()

    /** Pega texto respetando el «bracketed paste» de la app remota (sale por el responder). */
    fun paste(text: String)

    /** Modo «cursor de aplicación» (DECCKM): cambia la secuencia de las flechas. */
    val cursorKeysApplicationMode: Boolean
}
