package com.iaportafolio.argos.ui.sessions

import com.iaportafolio.argos.core.tmux.SessionGroup
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.ui.common.UiText

/** Paso del arranque mientras se conecta (port de los estados intermedios de `SessionsLoadState`). */
enum class ConnectStep {
    /** Conectando y comprobando que tmux esté instalado. */
    VERIFYING,

    /** Instalando tmux con `sudo apt` (solo si hay sudo sin contraseña). */
    INSTALLING,

    /** Creando un `~/.tmux.conf` base. */
    CONFIGURING,

    /** Listando sesiones. */
    LOADING,
}

/** Estado de conexión de la pantalla (equivale a `SessionsLoadState` de Apple). */
sealed interface SessionsLoad {
    data class Connecting(val step: ConnectStep) : SessionsLoad

    /** tmux no está y no se puede instalar sin contraseña: instrucción manual. */
    data object TmuxMissing : SessionsLoad

    /** La huella del servidor cambió: caso de seguridad con acción dedicada. */
    data class HostKeyChanged(val message: String) : SessionsLoad

    data class Failed(val message: String) : SessionsLoad

    /** El servidor ya no existe (borrado mientras la pantalla estaba abierta). */
    data object ServerMissing : SessionsLoad

    data object Loaded : SessionsLoad
}

/** Diálogo abierto en la pantalla de sesiones. */
sealed interface SessionDialog {
    /** Crear o renombrar: nombre tecleado y error de validación en vivo. */
    sealed interface NameInput : SessionDialog {
        val text: String
        val error: String?
        val isSubmitting: Boolean
    }

    data class Create(
        override val text: String = "",
        override val error: String? = null,
        override val isSubmitting: Boolean = false,
    ) : NameInput

    data class Rename(
        val session: TmuxSession,
        override val text: String,
        override val error: String? = null,
        override val isSubmitting: Boolean = false,
    ) : NameInput

    data class ConfirmKill(val session: TmuxSession) : SessionDialog
}

data class SessionsUiState(
    val serverName: String = "",
    val load: SessionsLoad = SessionsLoad.Connecting(ConnectStep.VERIFYING),
    val groups: List<SessionGroup> = emptyList(),
    /** Recarga con la lista visible (pull-to-refresh). */
    val isRefreshing: Boolean = false,
    val dialog: SessionDialog? = null,
    val message: UiText? = null,
) {
    /** Hay una operación de red de arranque en curso (deshabilita «Nueva sesión»). */
    val isBusy: Boolean get() = load is SessionsLoad.Connecting || isRefreshing
}
