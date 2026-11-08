package com.iaportafolio.argos.ui.sessions

import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.userMessage
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** Señal interna: el arranque se detuvo con la instrucción manual de instalar tmux. */
internal class TmuxMissingStop : Exception()

/**
 * Prepara tmux en el servidor (port del arranque de `SessionsViewModel` de Apple): detecta →
 * instala si hay sudo sin contraseña → configura → reenvío de portapapeles (best-effort).
 * [onStep] informa del paso en curso para la UI.
 */
internal suspend fun ensureTmuxEnvironment(
    service: SSHServicing,
    io: CoroutineDispatcher,
    onStep: (ConnectStep) -> Unit,
) {
    onStep(ConnectStep.VERIFYING)
    if (!withContext(io) { service.isTmuxInstalled() }) {
        if (!withContext(io) { service.canUseSudoNonInteractive() }) throw TmuxMissingStop()
        onStep(ConnectStep.INSTALLING)
        withContext(io) { service.installTmuxWithApt() }
    }
    if (!withContext(io) { service.tmuxConfigExists() }) {
        onStep(ConnectStep.CONFIGURING)
        withContext(io) { service.writeDefaultTmuxConfig() }
    }
    // OSC 52 (portapapeles) best-effort: el contrato dice que nunca lanza.
    withContext(io) { service.enableClipboardForwarding() }
}

private const val MAX_CAUSE_DEPTH = 8

/** Clasifica un fallo de conexión: huella cambiada y tmux ausente tienen pantalla propia. */
internal fun loadFailure(error: Throwable): SessionsLoad {
    val mismatch = generateSequence(error) { current -> current.cause?.takeIf { it !== current } }
        .take(MAX_CAUSE_DEPTH)
        .filterIsInstance<HostKeyMismatchException>()
        .firstOrNull()
    return when {
        mismatch != null -> SessionsLoad.HostKeyChanged(mismatch.userMessage)
        error is TmuxMissingStop || error is SSHServiceError.TmuxNotInstalled -> SessionsLoad.TmuxMissing
        else -> SessionsLoad.Failed(error.userMessage)
    }
}
