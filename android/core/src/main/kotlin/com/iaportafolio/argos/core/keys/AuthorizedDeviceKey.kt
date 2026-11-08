package com.iaportafolio.argos.core.keys

import java.security.MessageDigest
import java.time.DateTimeException
import java.time.LocalDate
import java.util.Base64

/**
 * Clave de un dispositivo autorizado por Argos en `authorized_keys` (comentario
 * `argos-iphone-…`). Port de `AuthorizedDeviceKey` en `ArgosCore/SSHKeyAuthorization.swift`.
 * Las demás claves del servidor se ignoran: Argos no las gestiona.
 */
data class AuthorizedDeviceKey(
    /** Comentario completo: identifica la línea para revocarla. */
    val comment: String,
    val keyType: String,
    /** Huella `SHA256:…` de la clave pública (como `ssh-keygen -lf`). */
    val fingerprint: String,
    /** Día en que se autorizó; `null` en las claves con el formato antiguo (sin fecha). */
    val authorizedOn: LocalDate?,
) {
    val id: String get() = comment

    /** Identificador corto para mostrar (primeros 8 caracteres del uuid). */
    val shortId: String
        get() {
            val rest = comment.drop(COMMENT_PREFIX.length)
            val uuid = if (authorizedOn == null) rest else rest.drop(STAMP_LENGTH + 1) // "AAAAMMDD-"
            return uuid.take(SHORT_ID_LENGTH)
        }

    companion object {
        /** Prefijo compartido con el Mac (no cambia aunque el dispositivo sea Android). */
        const val COMMENT_PREFIX = "argos-iphone-"
        private const val STAMP_LENGTH = 8
        private const val SHORT_ID_LENGTH = 8

        /** Fecha del comentario: `AAAAMMDD` (calendario gregoriano). */
        fun dateStamp(date: LocalDate): String =
            "%04d%02d%02d".format(date.year, date.monthValue, date.dayOfMonth)

        /** `AAAAMMDD` → fecha; `null` si no son 8 dígitos ASCII o el día es imposible. */
        fun dateFromStamp(stamp: String): LocalDate? {
            if (stamp.length != STAMP_LENGTH || !stamp.all { it in '0'..'9' }) return null
            val value = stamp.toInt()
            return try {
                LocalDate.of(value / 10_000, value / 100 % 100, value % 100)
            } catch (_: DateTimeException) {
                null // rechaza días imposibles (p. ej. 20261340)
            }
        }

        /**
         * Extrae las claves de Argos del contenido de `authorized_keys`. Tolera líneas en
         * blanco, comentarios `#` y opciones delante del tipo de clave.
         */
        fun parseAuthorizedKeys(text: String): List<AuthorizedDeviceKey> =
            text.lines().mapNotNull(::parseLine)

        fun parseLine(line: String): AuthorizedDeviceKey? {
            val trimmed = line.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("#")) return null
            val tokens = trimmed.split(Regex("\\s+"))
            val typeIndex = tokens.indexOfFirst(::isKeyType)
            if (typeIndex < 0 || typeIndex + 2 >= tokens.size) return null
            val blob = decodeStrictBase64(tokens[typeIndex + 1]) ?: return null
            val comment = tokens[typeIndex + 2]
            if (!comment.startsWith(COMMENT_PREFIX)) return null
            return AuthorizedDeviceKey(
                comment = comment,
                keyType = tokens[typeIndex],
                fingerprint = fingerprintOfBlob(blob),
                authorizedOn = dateFromComment(comment),
            )
        }

        /** Huella `SHA256:<base64 sin relleno>` del blob público (como `ssh-keygen -lf`). */
        fun fingerprintOfBlob(blob: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(blob)
            return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
        }

        private fun isKeyType(token: String): Boolean =
            token.startsWith("ssh-") || token.startsWith("ecdsa-") || token.startsWith("sk-")

        /** `argos-iphone-AAAAMMDD-<uuid>` → fecha; `argos-iphone-<uuid>` (antiguo) → null. */
        private fun dateFromComment(comment: String): LocalDate? {
            val rest = comment.drop(COMMENT_PREFIX.length)
            if (rest.length <= STAMP_LENGTH + 1 || rest[STAMP_LENGTH] != '-') return null
            return dateFromStamp(rest.take(STAMP_LENGTH))
        }

        /** Base64 estricto como `Data(base64Encoded:)`: exige relleno y longitud múltiplo de 4. */
        private fun decodeStrictBase64(text: String): ByteArray? {
            if (text.length % 4 != 0) return null
            return try {
                Base64.getDecoder().decode(text)
            } catch (_: IllegalArgumentException) {
                null
            }
        }
    }
}
