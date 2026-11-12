package com.iaportafolio.argos.core.tmux

import java.time.Instant

/**
 * Una sesión tmux en el servidor remoto (port de `ArgosCore/TmuxSession.swift`).
 *
 * Se parsea de una línea con el formato EXACTO de [TmuxCommands.SESSION_FORMAT].
 */
data class TmuxSession(
    /** `#{session_name}`: único por servidor tmux; es también la identidad de la sesión. */
    val name: String,
    /** `#{session_windows}`: número de ventanas abiertas. */
    val windowCount: Int,
    /** `#{session_attached}`: `true` si hay algún cliente conectado. */
    val isAttached: Boolean,
    /** `#{session_created}`: instante de creación. */
    val createdAt: Instant,
) {
    /** El nombre identifica la sesión de forma única dentro de un servidor tmux. */
    val id: String get() = name

    companion object {
        private const val FIELD_COUNT = 4
        private const val MILLIS_PER_SECOND = 1000.0

        /**
         * Parsea una línea de `tmux list-sessions -F`: `nombre|ventanas|attached(1/0)|created(epoch)`.
         * Devuelve `null` si la línea está vacía o no cumple el formato, para descartar líneas
         * inesperadas sin abortar el parseo del resto.
         */
        fun parse(line: String): TmuxSession? {
            val raw = line.trim()
            if (raw.isEmpty()) return null
            // Los tres últimos campos son numéricos; el nombre es todo lo anterior, porque tmux
            // admite '|' en un nombre de sesión (creada fuera de Argos).
            val fields = raw.split("|")
            if (fields.size < FIELD_COUNT) return null
            val numeric = fields.takeLast(FIELD_COUNT - 1)
            val name = fields.dropLast(FIELD_COUNT - 1).joinToString("|").takeIf { it.isNotEmpty() } ?: return null
            val windowCount = numeric[0].toIntOrNull() ?: return null
            val attachedFlag = numeric[1].toIntOrNull() ?: return null
            val epoch = numeric[2].toDoubleOrNull()?.takeIf { it.isFinite() } ?: return null
            return TmuxSession(
                name = name,
                windowCount = windowCount,
                isAttached = attachedFlag != 0,
                createdAt = Instant.ofEpochMilli((epoch * MILLIS_PER_SECOND).toLong()),
            )
        }
    }
}
