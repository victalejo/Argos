package com.iaportafolio.argos.ui.terminal

import com.iaportafolio.argos.data.TerminalSettings
import com.iaportafolio.argos.ui.common.UiText

/** Ciclo de vida del attach del terminal en vivo. */
sealed interface TerminalStatus {
    /** Abriendo el PTY. [attempt] 0 = primer intento; >0 = reintento automático. */
    data class Connecting(val attempt: Int = 0) : TerminalStatus

    data object Connected : TerminalStatus

    /**
     * La conexión falló o se cayó. [retryInSeconds] no nulo = hay un reintento automático
     * programado; nulo = hace falta pulsar «Reconectar».
     */
    data class Disconnected(val message: UiText, val retryInSeconds: Int?) : TerminalStatus

    /** tmux cerró el cliente (detach desde tmux o sesión terminada): no se reintenta solo. */
    data object SessionEnded : TerminalStatus
}

data class TerminalUiState(
    val sessionName: String,
    val serverName: String = "",
    val status: TerminalStatus = TerminalStatus.Connecting(),
    val modifiers: StickyModifiers = StickyModifiers(),
    val settings: TerminalSettings = TerminalSettings(),
)
