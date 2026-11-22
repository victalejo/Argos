package com.iaportafolio.argos.ui.terminal

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** Sesión tmux que un terminal comprobó que ya no existe en el servidor. */
data class VanishedSession(val serverId: String, val sessionName: String)

/**
 * Avisos de «esa sesión ya no existe» desde los terminales hacia la lista del servidor
 * (`ProjectsViewModel.sessionDidDisappear`), que vive en otro destino de la navegación. Solo en
 * memoria: si nadie escucha se pierde, y la lista se relee igualmente al volver a ella.
 */
class VanishedSessions {
    private val events = MutableSharedFlow<VanishedSession>(extraBufferCapacity = BUFFER)

    val vanished: Flow<VanishedSession> = events.asSharedFlow()

    fun report(serverId: String, sessionName: String) {
        events.tryEmit(VanishedSession(serverId, sessionName))
    }

    private companion object {
        const val BUFFER = 16
    }
}
