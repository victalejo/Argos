package com.iaportafolio.argos.core

import kotlinx.coroutines.CancellationException

/**
 * Detección de «esa sesión ya no existe» al enganchar el terminal (port de
 * `ArgosCore/Terminal/TerminalAttach.swift`). Sin esto, un `tmux attach` a una sesión muerta
 * cerraba el PTY y el terminal lo trataba como una caída de red: reintentaba sin fin en vez de
 * decir que la sesión terminó. El comando con target exacto es [tmux.TmuxCommands.attach].
 */
object TerminalAttach {

    /**
     * Ejecuta [open] (el PTY del `tmux attach` a [session]) pasando su salida por un
     * [TerminalAttachMonitor] antes de entregarla a [output]. Si el PTY termina (con normalidad o
     * con un error que no sea cancelación) después de que tmux dijera que la sesión no existe,
     * lanza [TerminalSessionMissingError] en lugar del resultado o del error original.
     */
    suspend fun monitoring(
        session: String,
        output: suspend (ByteArray) -> Unit,
        open: suspend (output: suspend (ByteArray) -> Unit) -> Unit,
    ) {
        val monitor = TerminalAttachMonitor()
        try {
            open { bytes ->
                monitor.consume(bytes)
                output(bytes)
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            if (monitor.sawMissingSession) throw TerminalSessionMissingError(session, error)
            throw error
        }
        if (monitor.sawMissingSession) throw TerminalSessionMissingError(session)
    }
}

/**
 * La sesión tmux a la que se quería enganchar el terminal ya no existe en el servidor (su último
 * proceso terminó o alguien la detuvo). Reintentar no sirve: hay que iniciarla.
 */
class TerminalSessionMissingError(val session: String, cause: Throwable? = null) :
    Exception("La sesión «$session» ya no existe en el servidor.", cause) {

    override fun equals(other: Any?): Boolean = other is TerminalSessionMissingError && other.session == session

    override fun hashCode(): Int = session.hashCode()
}

/**
 * Lee la salida del PTY ANTES de que tmux tome la pantalla y reconoce sus mensajes de «no hay
 * tal sesión». En cuanto tmux entra en la pantalla alternativa deja de mirar: lo que se imprima
 * dentro de la sesión nunca cuenta. Los trozos llegan en orden desde un solo lector; los
 * accesos van sincronizados porque quien lee el resultado puede estar en otro hilo.
 */
class TerminalAttachMonitor {

    var sawMissingSession: Boolean = false
        @Synchronized get
        private set

    var isAttached: Boolean = false
        @Synchronized get
        private set

    private var tail = ""

    /** Procesa un trozo de salida del PTY. */
    @Synchronized
    fun consume(bytes: ByteArray) {
        if (isAttached || sawMissingSession) return
        val text = tail + String(bytes, Charsets.UTF_8)
        if (ATTACHED_SEQUENCE in text) {
            isAttached = true
            tail = ""
            return
        }
        val lowered = text.lowercase()
        if (MISSING_SESSION_MESSAGES.any { it in lowered }) {
            sawMissingSession = true
            tail = ""
            return
        }
        tail = text.takeLast(TAIL_LENGTH)
    }

    companion object {
        /** Mensajes de tmux (no se traducen) cuando no hay sesión: 2.x+, 1.x y sin servidor. */
        val MISSING_SESSION_MESSAGES: List<String> = listOf(
            "can't find session",
            "session not found",
            "no server running",
            "no sessions",
        )

        /** `smcup` (pantalla alternativa): tmux la activa al engancharse. */
        const val ATTACHED_SEQUENCE = "\u001B[?1049h"

        /** Cola que se guarda entre trozos para no perder un mensaje partido en dos. */
        private const val TAIL_LENGTH = 64
    }
}
