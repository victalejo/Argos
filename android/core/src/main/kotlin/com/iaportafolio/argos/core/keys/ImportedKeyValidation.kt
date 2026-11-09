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
        PASTED_NOT_OPENSSH_KEY(
            "El texto no es una clave privada OpenSSH (debe incluir «-----BEGIN OPENSSH PRIVATE KEY-----»). " +
                "Argos admite claves Ed25519.",
        ),
        PASTED_INCOMPLETE(
            "La clave pegada está incompleta o dañada. Copia todo, desde «-----BEGIN» hasta «-----END OPENSSH PRIVATE KEY-----».",
        ),
    }

    private val BASE64_BODY = Regex("[A-Za-z0-9+/]+={0,2}")

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

    /**
     * Valida una clave pegada como texto y la devuelve en formato PEM canónico (líneas de 64).
     * Tolera lo que hacen las apps de mensajería y notas al copiar: saltos de línea convertidos
     * en espacios, `\r\n` y texto alrededor de la clave.
     */
    fun validatePasted(text: String): String {
        if (text.length > MAX_BYTES) throw ImportException(Reason.TOO_LARGE)
        val start = text.indexOf(HEADER)
        if (start < 0) throw ImportException(Reason.PASTED_NOT_OPENSSH_KEY)
        val bodyStart = start + HEADER.length
        val end = text.indexOf(OpenSSHKeyWriter.PEM_FOOTER, bodyStart)
        if (end < 0) throw ImportException(Reason.PASTED_INCOMPLETE)
        val body = text.substring(bodyStart, end).filterNot(Char::isWhitespace)
        if (!BASE64_BODY.matches(body)) throw ImportException(Reason.PASTED_INCOMPLETE)
        return "$HEADER\n${body.chunked(PEM_LINE_LENGTH).joinToString("\n")}\n${OpenSSHKeyWriter.PEM_FOOTER}\n"
    }

    private const val PEM_LINE_LENGTH = 64
}
