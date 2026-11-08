package com.iaportafolio.argos.core

/**
 * Saneado del tamaño del PTY remoto (port de `ArgosCore/PTYSize.swift`).
 *
 * Mientras se maqueta la vista, el emulador puede reportar tamaños transitorios absurdos
 * (p. ej. 2x1). Propagarlos como window-change hace que zsh 5.9 corrompa su heap en
 * `zrefresh()` y aborte, matando el shell antes de `exec tmux`.
 */
object PTYSize {
    /** Por debajo de esto el tamaño se considera transitorio (layout en curso). */
    const val MIN_COLS = 20
    const val MIN_ROWS = 5

    /** Tamaño del PTY cuando el terminal aún no tiene un tamaño utilizable. */
    const val FALLBACK_COLS = 80
    const val FALLBACK_ROWS = 24

    /** Columnas x filas de un terminal. */
    data class Dimensions(val cols: Int, val rows: Int)

    /** `true` si el tamaño es seguro para enviarlo como window-change. */
    fun isUsable(cols: Int, rows: Int): Boolean = cols >= MIN_COLS && rows >= MIN_ROWS

    /** Tamaño con el que abrir el PTY: el del terminal si es utilizable, o 80x24. */
    fun initial(cols: Int, rows: Int): Dimensions =
        if (isUsable(cols, rows)) Dimensions(cols, rows) else Dimensions(FALLBACK_COLS, FALLBACK_ROWS)
}
