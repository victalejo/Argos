package com.iaportafolio.argos.core.keys

import java.nio.charset.CharacterCodingException

/**
 * Validación de una clave privada importada (parte pura de `ArgosCore/ImportedKeyStore.swift`):
 * el almacenamiento cifrado vive en el módulo de datos de Android.
 */
object ImportedKeyValidation {

    const val HEADER = OpenSSHKeyWriter.PEM_HEADER

    /** Una clave Ed25519 ocupa ~400 bytes; 16 KB deja margen sin aceptar cualquier cosa. */
    const val MAX_BYTES = 16 * 1024

    /** Motivo por el que se rechaza un archivo de clave. */
    enum class Reason(val message: String) {
        NOT_OPENSSH_KEY(
            "El archivo no es una clave privada OpenSSH (debe empezar por «-----BEGIN OPENSSH PRIVATE KEY-----»). " +
                "Argos admite claves Ed25519.",
        ),
        TOO_LARGE("El archivo es demasiado grande para ser una clave SSH."),
        UNREADABLE("No se pudo leer el archivo de la clave."),
    }

    class ImportException(val reason: Reason) : Exception(reason.message)

    /** Comprueba que [data] parece una clave privada OpenSSH y la devuelve como texto normalizado. */
    fun validate(data: ByteArray): String {
        if (data.size > MAX_BYTES) throw ImportException(Reason.TOO_LARGE)
        val text = try {
            data.decodeToString(throwOnInvalidSequence = true)
        } catch (_: CharacterCodingException) {
            throw ImportException(Reason.UNREADABLE)
        }
        val trimmed = text.trim()
        if (!trimmed.startsWith(HEADER)) throw ImportException(Reason.NOT_OPENSSH_KEY)
        return trimmed + "\n"
    }
}
