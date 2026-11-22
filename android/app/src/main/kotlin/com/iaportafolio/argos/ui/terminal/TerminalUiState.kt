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

    /**
     * tmux dijo que la sesión ya no existe en el servidor (su último proceso terminó): no se
     * reintenta solo; la pantalla ofrece iniciarla de nuevo (proyecto) o «Reconectar».
     */
    data class SessionMissing(val message: UiText) : TerminalStatus
}

/** Aviso breve sobre el terminal (como `TerminalNotice` de iOS): subiendo, subido o error. */
sealed interface TerminalNotice {
    data class Uploading(val label: String) : TerminalNotice

    /** [typedPath] = la ruta ya está en la línea de comandos; si no (terminal sin conectar), se enseña. */
    data class Uploaded(val label: String, val remotePath: String, val typedPath: Boolean) : TerminalNotice

    data class Failed(val message: String) : TerminalNotice
}

data class TerminalUiState(
    val sessionName: String,
    val serverName: String = "",
    val status: TerminalStatus = TerminalStatus.Connecting(),
    val modifiers: StickyModifiers = StickyModifiers(),
    val settings: TerminalSettings = TerminalSettings(),
    val notice: TerminalNotice? = null,
)
