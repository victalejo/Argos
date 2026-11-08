package com.iaportafolio.argos.data

/** El token de Claude existe pero no se puede descifrar (clave del Keystore perdida…). */
class ClaudeTokenUnavailableException(cause: Throwable? = null) :
    Exception("No se pudo leer el token guardado de Claude. Bórralo y vuelve a pegarlo.", cause)

/**
 * Token de suscripción de `claude setup-token`. Como `KeychainStore.claudeOAuthToken` de Apple
 * es GLOBAL (de la cuenta, no del servidor) y solo de este dispositivo. Solo se lee justo antes
 * de lanzar o reanudar un agente; nunca debe llegar a logs, al estado de UI ni a mensajes.
 *
 * Operaciones bloqueantes (disco + criptografía): llamar fuera del hilo principal.
 */
interface ClaudeTokenStore {
    fun hasToken(): Boolean

    /** `null` si no hay token; lanza [ClaudeTokenUnavailableException] si no se puede leer. */
    fun read(): String?

    fun save(token: String)

    fun delete()
}

/** Cifrado con el [SecretStore] de la app, bajo un ámbito propio que no es ningún servidor. */
class SecretStoreClaudeTokens(private val secrets: SecretStore) : ClaudeTokenStore {

    override fun hasToken(): Boolean = secrets.contains(SCOPE, SecretKind.CLAUDE_OAUTH_TOKEN)

    override fun read(): String? = try {
        secrets.read(SCOPE, SecretKind.CLAUDE_OAUTH_TOKEN)
    } catch (error: SecretUnavailableException) {
        throw ClaudeTokenUnavailableException(error)
    }

    override fun save(token: String) = secrets.write(SCOPE, SecretKind.CLAUDE_OAUTH_TOKEN, token)

    override fun delete() = secrets.delete(SCOPE, SecretKind.CLAUDE_OAUTH_TOKEN)

    private companion object {
        /** No es un UUID: no puede coincidir con el id de un servidor (ni borrarse con él). */
        const val SCOPE = "argos.claude.account"
    }
}

/** Validación del token pegado. Viaja como UNA línea por stdin: sin espacios ni controles. */
object ClaudeTokenValidation {
    private const val MAX_LENGTH = 4_096

    /** El token sin espacios alrededor, o `null` si no es válido. */
    fun normalize(raw: String): String? {
        val token = raw.trim()
        val valid = token.isNotEmpty() &&
            token.length <= MAX_LENGTH &&
            token.none { it.isWhitespace() || it.isISOControl() }
        return token.takeIf { valid }
    }
}
