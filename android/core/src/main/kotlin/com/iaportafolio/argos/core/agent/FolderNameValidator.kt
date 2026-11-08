package com.iaportafolio.argos.core.agent

/**
 * Valida el nombre de una carpeta nueva del servidor: una sola carpeta, sin rutas (port de
 * `ArgosCore/Agent/FolderNameValidator.swift`).
 */
object FolderNameValidator {

    /** Motivo por el que un nombre no vale, con su mensaje para la UI. */
    enum class Failure(val message: String) {
        EMPTY("Escribe un nombre para la carpeta."),
        RESERVED("«.» y «..» no son nombres válidos."),
        CONTAINS_SLASH("El nombre no puede llevar «/». Crea una carpeta cada vez."),
        CONTROL_CHARACTER("El nombre tiene caracteres no válidos."),
        TOO_LONG("El nombre es demasiado largo (máximo 255 bytes)."),
    }

    /** Resultado de [validate]. */
    sealed interface Result {
        /** Nombre válido, ya sin espacios sobrantes. */
        data class Valid(val name: String) : Result

        data class Invalid(val failure: Failure) : Result
    }

    private const val MAX_UTF8_BYTES = 255

    /** Devuelve el nombre sin espacios sobrantes o el motivo por el que no vale. */
    fun validate(raw: String): Result {
        val name = SwiftText.trimWhitespaceAndNewlines(raw)
        val failure = when {
            name.isEmpty() -> Failure.EMPTY
            name == "." || name == ".." -> Failure.RESERVED
            name.contains("/") -> Failure.CONTAINS_SLASH
            name.codePoints().anyMatch(::isControl) -> Failure.CONTROL_CHARACTER
            name.toByteArray(Charsets.UTF_8).size > MAX_UTF8_BYTES -> Failure.TOO_LONG
            else -> return Result.Valid(name)
        }
        return Result.Invalid(failure)
    }

    /** `CharacterSet.controlCharacters`: categorías Unicode Cc y Cf. */
    private fun isControl(codePoint: Int): Boolean {
        val type = Character.getType(codePoint)
        return type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()
    }
}
