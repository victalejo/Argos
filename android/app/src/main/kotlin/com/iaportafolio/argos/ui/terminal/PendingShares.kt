package com.iaportafolio.argos.ui.terminal

import com.iaportafolio.argos.data.PickedAttachment

/**
 * Lo que se compartió con Argos desde otra app («Compartir» → Argos → proyecto), a la espera de que
 * el terminal de esa sesión se conecte para subirlo. Solo en memoria: los permisos de lectura de los
 * `content://` compartidos duran lo que la Activity, no tiene sentido guardarlos.
 */
class PendingShares {
    private val pending = mutableMapOf<Pair<String, String>, List<PickedAttachment>>()

    @Synchronized
    fun put(serverId: String, session: String, attachments: List<PickedAttachment>) {
        if (attachments.isEmpty()) return
        val key = serverId to session
        pending[key] = pending[key].orEmpty() + attachments
    }

    /** Se los lleva (una sola vez). */
    @Synchronized
    fun take(serverId: String, session: String): List<PickedAttachment> = pending.remove(serverId to session).orEmpty()
}
