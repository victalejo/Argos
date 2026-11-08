package com.iaportafolio.argos.core

/** Estado observable de la conexión del terminal en vivo (port de `LiveTerminalStatus`). */
sealed interface LiveTerminalStatus {
    data object Connecting : LiveTerminalStatus
    data object Connected : LiveTerminalStatus
    data object Ended : LiveTerminalStatus
    data class Failed(val message: String) : LiveTerminalStatus
}

/**
 * Estado de conexión de una sesión, para el indicador de la lista
 * (port de `ArgosCore/SessionConnectionState.swift`).
 */
enum class SessionConnectionState {
    /** Cargada y conectada por nosotros. */
    LIVE,

    /** Estableciendo la conexión. */
    CONNECTING,

    /** Falló la conexión. */
    ERROR,

    /** tmux la reporta adjunta, pero no por esta app. */
    ATTACHED_ELSEWHERE,

    /** No cargada (nunca abierta o desconectada). */
    DORMANT,
    ;

    companion object {
        /**
         * Mapeo puro: estado del terminal local + flag de tmux → estado visual.
         * `status == null` significa que no hay terminal cargado para la sesión.
         */
        fun from(status: LiveTerminalStatus?, isAttached: Boolean): SessionConnectionState = when (status) {
            LiveTerminalStatus.Connecting -> CONNECTING
            LiveTerminalStatus.Connected -> LIVE
            is LiveTerminalStatus.Failed -> ERROR
            LiveTerminalStatus.Ended, null -> if (isAttached) ATTACHED_ELSEWHERE else DORMANT
        }
    }
}
