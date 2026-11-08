package com.iaportafolio.argos.ui.form

import com.iaportafolio.argos.core.AuthMethod

/** Campos del formulario de servidor que pueden tener error. */
enum class FormField { NAME, HOST, PORT, USERNAME, PASSWORD, KEY, PASSPHRASE }

/** Motivo de error de un campo (el texto en español vive en `strings.xml`). */
enum class FieldError {
    NAME_REQUIRED,
    HOST_REQUIRED,
    HOST_INVALID,
    PORT_INVALID,
    USERNAME_REQUIRED,
    USERNAME_INVALID,
    PASSWORD_REQUIRED,
    KEY_REQUIRED,
    PASSPHRASE_REQUIRED,
}

/** Lo que el validador necesita saber del formulario (sin secretos: solo si están vacíos). */
data class FormInput(
    val name: String,
    val host: String,
    val port: String,
    val username: String,
    val authMethod: AuthMethod,
    val passwordEntered: Boolean,
    /** Ya hay una contraseña guardada que sirve (editar sin teclearla = sin cambios). */
    val hasStoredPassword: Boolean,
    val hasKey: Boolean,
    val requiresPassphrase: Boolean,
    val passphraseEntered: Boolean,
    val hasStoredPassphrase: Boolean,
)

/** Validación pura del formulario de servidor (equivale a `canSave` de `ServerFormView`). */
object ServerFormValidation {

    private const val MIN_PORT = 1
    private const val MAX_PORT = 65_535

    /** Caracteres que nunca forman parte de un host (ni nombre, ni IPv4, ni IPv6). */
    private val FORBIDDEN_HOST_CHARACTERS = setOf('@', '/', '\\', '?', '#')

    fun validate(input: FormInput): Map<FormField, FieldError> = buildMap {
        if (input.name.isBlank()) put(FormField.NAME, FieldError.NAME_REQUIRED)
        hostError(input.host.trim())?.let { put(FormField.HOST, it) }
        if (parsePort(input.port) == null) put(FormField.PORT, FieldError.PORT_INVALID)
        usernameError(input.username.trim())?.let { put(FormField.USERNAME, it) }
        when (input.authMethod) {
            AuthMethod.PASSWORD -> if (!input.passwordEntered && !input.hasStoredPassword) {
                put(FormField.PASSWORD, FieldError.PASSWORD_REQUIRED)
            }
            AuthMethod.KEY -> {
                if (!input.hasKey) put(FormField.KEY, FieldError.KEY_REQUIRED)
                if (input.requiresPassphrase && !input.passphraseEntered && !input.hasStoredPassphrase) {
                    put(FormField.PASSPHRASE, FieldError.PASSPHRASE_REQUIRED)
                }
            }
        }
    }

    /** Puerto válido (1–65535) o `null`. */
    fun parsePort(raw: String): Int? = raw.trim().toIntOrNull()?.takeIf { it in MIN_PORT..MAX_PORT }

    private fun hostError(host: String): FieldError? = when {
        host.isEmpty() -> FieldError.HOST_REQUIRED
        host.startsWith("-") -> FieldError.HOST_INVALID
        host.any { it.isWhitespace() || it.isISOControl() || it in FORBIDDEN_HOST_CHARACTERS } -> FieldError.HOST_INVALID
        else -> null
    }

    private fun usernameError(username: String): FieldError? = when {
        username.isEmpty() -> FieldError.USERNAME_REQUIRED
        username.startsWith("-") -> FieldError.USERNAME_INVALID
        username.any { it.isWhitespace() || it.isISOControl() || it == '@' } -> FieldError.USERNAME_INVALID
        else -> null
    }
}
