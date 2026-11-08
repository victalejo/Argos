package com.iaportafolio.argos.core

import kotlinx.coroutines.flow.Flow

/**
 * Evento que viaja desde la vista del terminal (UI) hacia el PTY remoto (port de
 * `TerminalControlEvent` en `ArgosCore/SSHTerminalSession.swift`).
 */
sealed interface TerminalControlEvent {

    /** Bytes tecleados que se escriben en el stdin del PTY. */
    class Input(val bytes: ByteArray) : TerminalControlEvent

    /** Nuevo tamaño del terminal (`window-change`). */
    data class Resize(val cols: Int, val rows: Int) : TerminalControlEvent
}

/**
 * Canales PTY en streaming. Separado de [SSHServicing] para no obligar a los dobles de test
 * que no los usan a implementarlos.
 *
 * Ciclo de vida (detach, NO kill), igual que Apple: cancelar la corrutina que llama a
 * [attachTerminal] cierra el canal; el `tmux attach` remoto recibe SIGHUP y tmux
 * desengancha a este cliente, pero la sesión sigue viva en el servidor. Si el usuario hace
 * detach desde tmux, el PTY emite EOF y la función retorna con normalidad.
 */
interface TerminalStreaming {

    /**
     * Abre un PTY interactivo y ejecuta `tmux attach -t <session>` ([tmux.TmuxCommands.attach]).
     * Suspende mientras el canal está abierto: entrega cada bloque de salida (stdout y stderr)
     * a [output] en orden y aplica los eventos de [control]. Lanza [SSHServiceError] o la
     * excepción de conexión si no puede abrirse.
     */
    suspend fun attachTerminal(
        session: String,
        initialCols: Int,
        initialRows: Int,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    )

    /** Igual que [attachTerminal] pero ejecutando [command] tal cual en el PTY. */
    suspend fun attachCommand(
        command: String,
        initialCols: Int,
        initialRows: Int,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    )
}
