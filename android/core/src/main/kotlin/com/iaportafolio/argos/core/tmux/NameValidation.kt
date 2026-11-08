package com.iaportafolio.argos.core.tmux

/**
 * Utilidades compartidas por [SessionNameValidator] y [WindowNameValidator].
 *
 * Equivale a `CharacterSet.controlCharacters` de Apple: categorías Unicode Cc y Cf.
 */
internal fun String.containsControlCharacter(): Boolean = codePoints().anyMatch { codePoint ->
    val type = Character.getType(codePoint)
    type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()
}

internal const val EMPTY_NAME_MESSAGE = "El nombre no puede estar vacío."
internal const val CONTROL_CHARACTER_MESSAGE =
    "El nombre no puede contener saltos de línea, tabuladores ni otros caracteres de control."
internal const val LEADING_DASH_MESSAGE =
    "El nombre no puede empezar por '-' (tmux lo interpretaría como una opción)."
