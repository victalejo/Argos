package com.iaportafolio.argos.core.tmux

/**
 * Una ventana dentro de una sesión tmux (port de `ArgosCore/TmuxWindow.swift`).
 *
 * Se parsea de una línea con el formato de [TmuxCommands.LIST_WINDOWS_FORMAT]; el nombre va
 * AL FINAL para que un '|' dentro de él no rompa el parseo.
 */
data class TmuxWindow(
    /** `#{window_index}`: único dentro de la sesión; es también su identidad. */
    val index: Int,
    /** `#{window_name}`. */
    val name: String,
    /** `#{window_active}`: `true` si es la ventana activa de la sesión. */
    val isActive: Boolean,
    /** `#{window_panes}`: número de paneles. */
    val paneCount: Int,
    /** `#{@argos_color}`: color elegido por el usuario, o `null`. */
    val color: WindowColor? = null,
    /**
     * `#{pane_current_command}`: proceso en primer plano del panel activo (`zsh`, `claude`,
     * `vim`…), o `null` si tmux no lo informó.
     */
    val currentCommand: String? = null,
) {
    val id: Int get() = index

    companion object {
        private const val FIELD_COUNT = 6

        /**
         * Parsea una línea de `tmux list-windows -F`: `índice|activa(1/0)|paneles|color|comando|nombre`,
         * donde el nombre es el resto de la línea. Devuelve `null` si no cumple. Un color
         * desconocido se trata como "sin color".
         */
        fun parse(line: String): TmuxWindow? {
            val raw = line.trim()
            if (raw.isEmpty()) return null
            val fields = raw.split("|", limit = FIELD_COUNT)
            if (fields.size != FIELD_COUNT) return null
            val index = fields[0].toIntOrNull() ?: return null
            val activeFlag = fields[1].toIntOrNull() ?: return null
            val paneCount = fields[2].toIntOrNull() ?: return null
            val name = fields[5].takeIf { it.isNotEmpty() } ?: return null
            return TmuxWindow(
                index = index,
                name = name,
                isActive = activeFlag != 0,
                paneCount = paneCount,
                color = WindowColor.fromRawValue(fields[3]),
                currentCommand = fields[4].ifEmpty { null },
            )
        }
    }
}

/**
 * Paleta para etiquetar ventanas. [rawValue] es lo que se guarda en la opción de usuario
 * `@argos_color` de tmux (persiste en el servidor).
 */
enum class WindowColor(val rawValue: String, val displayName: String) {
    RED("red", "Rojo"),
    ORANGE("orange", "Naranja"),
    YELLOW("yellow", "Amarillo"),
    GREEN("green", "Verde"),
    MINT("mint", "Menta"),
    BLUE("blue", "Azul"),
    PURPLE("purple", "Morado"),
    PINK("pink", "Rosa"),
    GRAY("gray", "Gris"),
    ;

    val id: String get() = rawValue

    companion object {
        /** Color con ese `rawValue`, o `null` si no existe (equivale a `WindowColor(rawValue:)`). */
        fun fromRawValue(rawValue: String): WindowColor? = entries.firstOrNull { it.rawValue == rawValue }
    }
}
