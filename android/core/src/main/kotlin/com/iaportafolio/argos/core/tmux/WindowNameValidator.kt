package com.iaportafolio.argos.core.tmux

/**
 * Valida nombres de ventana tmux (port de `WindowNameValidator` en `ArgosCore/TmuxWindow.swift`).
 * Más permisivo que [SessionNameValidator]: las ventanas se apuntan por índice, así que ':' y
 * '.' sí se admiten.
 */
object WindowNameValidator {

    sealed class ValidationError(message: String) : Exception(message, null, false, false) {
        data object Empty : ValidationError(EMPTY_NAME_MESSAGE)

        data object ControlCharacter : ValidationError(CONTROL_CHARACTER_MESSAGE)

        data object LeadingDash : ValidationError(LEADING_DASH_MESSAGE)
    }

    /** Valida y normaliza (recorta espacios). Lanza [ValidationError] si es inválido. */
    fun validate(rawName: String): String {
        val trimmed = rawName.trim()
        if (trimmed.isEmpty()) throw ValidationError.Empty
        if (trimmed.containsControlCharacter()) throw ValidationError.ControlCharacter
        if (trimmed.startsWith("-")) throw ValidationError.LeadingDash
        return trimmed
    }

    fun isValid(rawName: String): Boolean = runCatching { validate(rawName) }.isSuccess

    /** Mensaje para feedback en vivo, o `null` si es válido (o aún está vacío). */
    fun liveValidationMessage(rawName: String): String? = when (val error = runCatching { validate(rawName) }.exceptionOrNull()) {
        null, ValidationError.Empty -> null
        else -> error.message
    }
}
