package com.iaportafolio.argos.core.projects

/**
 * Qué grupos de sesiones ("grupo/nombre") están colapsados en la barra lateral, por servidor
 * (la parte pura de `ArgosCore/CollapsedSessionGroups.swift`). Valor INMUTABLE: [toggled]
 * devuelve una copia; la plataforma persiste [keys] (Apple: `UserDefaults`, clave
 * [DEFAULTS_KEY], array ordenado — ver [sortedKeys]).
 */
data class CollapsedSessionGroups(
    /** Claves "<servidor>/<grupo>" de los grupos colapsados. */
    val keys: Set<String> = emptySet(),
) {
    fun isCollapsed(serverId: String, group: String): Boolean = key(serverId, group) in keys

    fun toggled(serverId: String, group: String): CollapsedSessionGroups {
        val key = key(serverId, group)
        return copy(keys = if (key in keys) keys - key else keys + key)
    }

    /** Lo que se persiste (Apple guarda `collapsed.sorted()`). */
    val sortedKeys: List<String> get() = keys.sorted()

    companion object {
        const val DEFAULTS_KEY = "collapsedSessionGroups"

        /**
         * El grupo es el prefijo ANTES del primer '/', así que nunca contiene '/' y
         * "<uuid>/<grupo>" es inequívoco. El id del servidor va como `uuidString` de Apple.
         */
        fun key(serverId: String, group: String): String = "${serverId.uppercase()}/$group"
    }
}
