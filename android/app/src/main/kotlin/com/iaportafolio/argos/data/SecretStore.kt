package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.keys.ImportedKeyValidation
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.MessageDigest

/** Tipo de secreto guardado para un servidor. */
enum class SecretKind(internal val fileSuffix: String) {
    PASSWORD("password"),
    PASSPHRASE("passphrase"),
    PRIVATE_KEY("key"),
}

/** Un secreto existe pero no se puede leer (clave del Keystore perdida, archivo alterado…). */
class SecretUnavailableException(kind: SecretKind, cause: Throwable? = null) : Exception(
    when (kind) {
        SecretKind.PASSWORD -> "No se pudo leer la contraseña guardada."
        SecretKind.PASSPHRASE -> "No se pudo leer la passphrase guardada."
        SecretKind.PRIVATE_KEY -> "No se pudo leer la clave privada importada."
    } + " Edita el servidor y vuelve a introducirla.",
    cause,
)

/**
 * Secretos de los servidores: contraseñas, passphrases y claves privadas importadas
 * (equivale a `KeychainStore` + `ImportedKeyStore` de Apple). Nunca se guardan en claro.
 *
 * Operaciones bloqueantes (disco + criptografía): llamar fuera del hilo principal.
 */
interface SecretStore {
    /** `null` si no hay secreto de ese tipo; lanza [SecretUnavailableException] si existe pero no se puede leer. */
    fun read(serverId: String, kind: SecretKind): String?

    fun contains(serverId: String, kind: SecretKind): Boolean

    fun write(serverId: String, kind: SecretKind, value: String)

    fun delete(serverId: String, kind: SecretKind)

    /** Borra todos los secretos del servidor y su clave de cifrado. */
    fun deleteAll(serverId: String)

    /**
     * Valida [data] con [ImportedKeyValidation] (lanza su `ImportException` con el motivo) y
     * guarda la clave normalizada cifrada.
     */
    fun importPrivateKey(serverId: String, data: ByteArray) {
        write(serverId, SecretKind.PRIVATE_KEY, ImportedKeyValidation.validate(data))
    }
}

/**
 * [SecretStore] en archivos cifrados (`<dir>/<token>.<tipo>.bin`) con un [SecretCipher] por
 * servidor. El nombre de archivo y el alias de la clave usan un hash del id (no el id en
 * crudo), así un id de un `servers.json` ajeno no puede escapar del directorio. El AAD ata cada
 * blob a su servidor y tipo: copiar el archivo de la contraseña sobre el de otro servidor
 * hace fallar el descifrado en vez de entregar el secreto equivocado.
 */
class EncryptedSecretStore(
    private val directory: File,
    private val cipher: SecretCipher,
) : SecretStore {

    private val lock = Any()

    override fun read(serverId: String, kind: SecretKind): String? = synchronized(lock) {
        val file = fileFor(serverId, kind)
        if (!file.exists()) return null
        try {
            cipher.decrypt(token(serverId), file.readBytes(), aad(serverId, kind)).decodeToString()
        } catch (error: GeneralSecurityException) {
            ArgosLog.error(ArgosLog.TAG_SECRETS, "No se pudo descifrar ${kind.name} de $serverId", error)
            throw SecretUnavailableException(kind, error)
        } catch (error: IOException) {
            ArgosLog.error(ArgosLog.TAG_SECRETS, "No se pudo leer ${kind.name} de $serverId", error)
            throw SecretUnavailableException(kind, error)
        }
    }

    override fun contains(serverId: String, kind: SecretKind): Boolean = synchronized(lock) {
        fileFor(serverId, kind).exists()
    }

    override fun write(serverId: String, kind: SecretKind, value: String) = synchronized(lock) {
        val blob = cipher.encrypt(token(serverId), value.encodeToByteArray(), aad(serverId, kind))
        AtomicFiles.write(fileFor(serverId, kind), blob)
    }

    override fun delete(serverId: String, kind: SecretKind) {
        synchronized(lock) { deleteFile(fileFor(serverId, kind)) }
    }

    override fun deleteAll(serverId: String) = synchronized(lock) {
        SecretKind.entries.forEach { deleteFile(fileFor(serverId, it)) }
        cipher.deleteKey(token(serverId))
    }

    private fun deleteFile(file: File) {
        if (file.exists() && !file.delete()) {
            ArgosLog.warn(ArgosLog.TAG_SECRETS, "No se pudo borrar ${file.name}")
        }
    }

    private fun fileFor(serverId: String, kind: SecretKind) = File(directory, "${token(serverId)}.${kind.fileSuffix}.bin")

    private fun aad(serverId: String, kind: SecretKind) = "argos:$serverId:${kind.fileSuffix}".encodeToByteArray()

    internal companion object {
        private const val TOKEN_BYTES = 16

        /** Hash corto y estable del id: seguro como nombre de archivo y alias del Keystore. */
        fun token(serverId: String): String = MessageDigest.getInstance("SHA-256")
            .digest(serverId.encodeToByteArray())
            .take(TOKEN_BYTES)
            .joinToString("") { "%02x".format(it) }
    }
}
