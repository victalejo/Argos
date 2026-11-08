package com.iaportafolio.argos.core.tmux

/**
 * Valida (y normaliza) nombres de sesión tmux (port de `ArgosCore/SessionNameValidator.swift`).
 *
 * tmux usa ':' y '.' como separadores de target (sesión:ventana.panel), así que los PROHÍBE en
 * el nombre de una sesión. El '/' SÍ se permite y se usa por convención para agrupar
 * (ver [SessionGrouping]).
 */
object SessionNameValidator {

    /** Motivos por los que un nombre puede ser inválido. El `message` es el texto para la UI. */
    sealed class ValidationError(message: String) : Exception(message, null, false, false) {
        data object Empty : ValidationError(EMPTY_NAME_MESSAGE)

        data class ForbiddenCharacter(val character: Char) : ValidationError(
            "El nombre no puede contener '$character': tmux usa ':' y '.' como separadores de sesión.",
        )

        data object ControlCharacter : ValidationError(CONTROL_CHARACTER_MESSAGE)

        data object LeadingDash : ValidationError(LEADING_DASH_MESSAGE)
    }

    /** Caracteres que tmux NO admite en un nombre de sesión (el '/' se permite a propósito). */
    val FORBIDDEN_CHARACTERS: List<Char> = listOf(':', '.')

    /**
     * Valida y normaliza (recorta espacios alrededor). Devuelve el nombre listo para tmux o
     * lanza [ValidationError].
     *
     * Defensa en profundidad: aunque `ShellQuoting` neutraliza el shell, se rechazan caracteres
     * de control (un '\n' rompería el parseo por líneas de `list-sessions`) y el prefijo '-'
     * (inyección de OPCIONES a tmux).
     */
    fun validate(rawName: String): String {
        val trimmed = rawName.trim()
        if (trimmed.isEmpty()) throw ValidationError.Empty
        if (trimmed.containsControlCharacter()) throw ValidationError.ControlCharacter
        FORBIDDEN_CHARACTERS.firstOrNull { it in trimmed }?.let { throw ValidationError.ForbiddenCharacter(it) }
        if (trimmed.startsWith("-")) throw ValidationError.LeadingDash
        return trimmed
    }

    /** ¿Es válido el nombre? Útil para habilitar/deshabilitar el botón de envío. */
    fun isValid(rawName: String): Boolean = runCatching { validate(rawName) }.isSuccess

    /**
     * Mensaje para feedback en vivo, o `null` si es válido. No reporta el caso "vacío" para no
     * mostrar un error antes de que el usuario teclee nada.
     */
    fun liveValidationMessage(rawName: String): String? = when (val error = runCatching { validate(rawName) }.exceptionOrNull()) {
        null, ValidationError.Empty -> null
        else -> error.message
    }
}
