package com.iaportafolio.argos.core.keys

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.URISyntaxException
import java.nio.charset.CharacterCodingException
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Base64
import java.util.UUID

/**
 * Contenido del QR con el que el Mac pasa un servidor al móvil (port de
 * `ArgosCore/ServerTransfer.swift`). Es un enlace `argos://add-server?d=<base64url(JSON)>`.
 *
 * Lleva la semilla de una clave Ed25519 CREADA SOLO para ese dispositivo (el Mac ya la
 * añadió al `authorized_keys` del servidor). Caduca a los [LIFETIME] y trae la huella de
 * host key que el Mac ya verificó, para no confiar a ciegas en la primera conexión.
 *
 * [keySeed] es secreto: [toString] no lo muestra.
 */
class ServerTransfer(
    val name: String,
    val host: String,
    val port: Int,
    val username: String,
    keySeed: ByteArray,
    /** Comentario de la clave en `authorized_keys` (para identificarla y revocarla). */
    val keyComment: String,
    /** Huella `SHA256:…` de la host key confiada por el Mac, si la conoce. */
    val hostKeyFingerprint: String?,
    val createdAt: Instant,
) {
    private val seed: ByteArray = keySeed.copyOf()

    /** Semilla (32 bytes) de la clave Ed25519 dedicada. Devuelve una copia. */
    val keySeed: ByteArray get() = seed.copyOf()

    fun copy(
        name: String = this.name,
        host: String = this.host,
        port: Int = this.port,
        username: String = this.username,
        keySeed: ByteArray = this.seed,
        keyComment: String = this.keyComment,
        hostKeyFingerprint: String? = this.hostKeyFingerprint,
        createdAt: Instant = this.createdAt,
    ): ServerTransfer = ServerTransfer(name, host, port, username, keySeed, keyComment, hostKeyFingerprint, createdAt)

    /** Validación de campos (los datos vienen de fuera: nunca se confía en ellos). */
    val isValid: Boolean
        get() {
            val fields = listOf(name, host, username)
            val fieldsOk = fields.none { it.isEmpty() || hasControlCharacters(it) } &&
                host.none(Char::isWhitespace) && username.none(Char::isWhitespace) &&
                !host.startsWith("-") && !username.startsWith("-")
            val keyOk = port in 1..MAX_PORT && seed.size == Ed25519Key.SEED_SIZE &&
                keyComment.isNotEmpty() && keyComment.none(Char::isWhitespace)
            val fingerprintOk = hostKeyFingerprint?.startsWith("SHA256:") ?: true
            return fieldsOk && keyOk && fingerprintOk
        }

    /** Enlace que se codifica en el QR. */
    fun urlString(): String {
        val payload = Payload(
            v = CURRENT_VERSION, n = name, h = host, p = port, u = username,
            k = base64UrlEncode(seed), c = keyComment, f = hostKeyFingerprint,
            t = createdAt.epochSecond,
        )
        val json = JSON.encodeToString(Payload.serializer(), payload)
        return "$SCHEME://$ACTION?d=${base64UrlEncode(json.toByteArray(Charsets.UTF_8))}"
    }

    /**
     * `true` si trae una huella distinta de [trustedFingerprint], la que este dispositivo ya
     * confía para su host:puerto (el almacén TOFU lo resuelve quien llama).
     */
    fun conflictsWithTrustedHostKey(trustedFingerprint: String?): Boolean =
        hostKeyFingerprint != null && trustedFingerprint != null && trustedFingerprint != hostKeyFingerprint

    /** Clave privada en formato OpenSSH, lista para guardarla como clave importada. */
    fun privateKeyPem(): String = OpenSSHKeyWriter.privateKeyPem(Ed25519Key.fromSeed(seed), keyComment)

    override fun equals(other: Any?): Boolean =
        other is ServerTransfer && name == other.name && host == other.host && port == other.port &&
            username == other.username && seed.contentEquals(other.seed) && keyComment == other.keyComment &&
            hostKeyFingerprint == other.hostKeyFingerprint && createdAt == other.createdAt

    override fun hashCode(): Int =
        listOf(name, host, port, username, seed.contentHashCode(), keyComment, hostKeyFingerprint, createdAt)
            .hashCode()

    override fun toString(): String =
        "ServerTransfer(name=$name, host=$host, port=$port, username=$username, keySeed=<oculta>, " +
            "keyComment=$keyComment, hostKeyFingerprint=$hostKeyFingerprint, createdAt=$createdAt)"

    /** La identidad del servidor del QR no coincide con la que ya confía este dispositivo. */
    class HostKeyConflictException(val endpoint: String) : Exception(
        "La identidad de $endpoint del código no coincide con la que ya conoce este dispositivo. " +
            "No se añadió el servidor. Si reinstalaste el servidor, usa «Olvidar host key» y vuelve a escanear.",
    )

    /** Motivo por el que un QR escaneado no se acepta. */
    enum class DecodeError(val message: String) {
        NOT_ARGOS_CODE("Este código QR no es de Argos. En el Mac, abre el menú del servidor y elige «Enviar al iPhone…»."),
        MALFORMED("El código QR está incompleto o dañado. Genera otro en el Mac."),
        UNSUPPORTED_VERSION("Este código lo generó otra versión de Argos. Actualiza Argos en el Mac y en el iPhone."),
        EXPIRED("El código QR caducó (dura 5 minutos). En el Mac, pulsa «Mostrar de nuevo»."),
        INVALID_DATA("El código QR contiene datos de servidor no válidos. Genera otro en el Mac."),
    }

    class DecodeException(val error: DecodeError) : Exception(error.message)

    /** Forma compacta (mismas claves que el `Payload` de Swift) para que el QR sea pequeño. */
    @Serializable
    private data class Payload(
        @SerialName("v") val v: Int,
        @SerialName("n") val n: String,
        @SerialName("h") val h: String,
        @SerialName("p") val p: Int,
        @SerialName("u") val u: String,
        @SerialName("k") val k: String,
        @SerialName("c") val c: String,
        @SerialName("f") val f: String? = null,
        @SerialName("t") val t: Long,
    )

    companion object {
        const val CURRENT_VERSION = 1
        /** Validez del QR desde que se genera. */
        val LIFETIME: Duration = Duration.ofMinutes(5)
        /** Margen por relojes desajustados entre Mac y móvil. */
        val CLOCK_SKEW: Duration = Duration.ofSeconds(60)
        const val SCHEME = "argos"
        const val ACTION = "add-server"
        private const val MAX_PORT = 65_535

        /** Como `JSONEncoder`/`JSONDecoder`: omite `f` nulo e ignora claves desconocidas. */
        private val JSON = Json {
            explicitNulls = false
            ignoreUnknownKeys = true
        }

        /** Lee y valida un enlace escaneado. [now] se inyecta en tests. */
        fun decode(text: String, now: Instant = Instant.now()): ServerTransfer {
            val uri = parseUri(text.trim())
            if (uri?.scheme?.lowercase() != SCHEME || uri.host?.lowercase() != ACTION) {
                throw DecodeException(DecodeError.NOT_ARGOS_CODE)
            }
            val payload = queryValue(uri.rawQuery, "d")
                ?.let(::base64UrlDecode)
                ?.let(::decodePayload)
                ?: throw DecodeException(DecodeError.MALFORMED)

            if (payload.v != CURRENT_VERSION) throw DecodeException(DecodeError.UNSUPPORTED_VERSION)

            val createdAt = Instant.ofEpochSecond(payload.t)
            val age = Duration.between(createdAt, now)
            if (age > LIFETIME || age < CLOCK_SKEW.negated()) throw DecodeException(DecodeError.EXPIRED)

            val seed = base64UrlDecode(payload.k)
            if (seed == null || seed.size != Ed25519Key.SEED_SIZE) throw DecodeException(DecodeError.INVALID_DATA)
            val transfer = ServerTransfer(
                name = payload.n.trim(),
                host = payload.h.trim(),
                port = payload.p,
                username = payload.u.trim(),
                keySeed = seed,
                keyComment = payload.c,
                hostKeyFingerprint = payload.f,
                createdAt = createdAt,
            )
            if (!transfer.isValid) throw DecodeException(DecodeError.INVALID_DATA)
            return transfer
        }

        /**
         * Comentario único con el que se identifica la clave en `authorized_keys`:
         * `argos-iphone-<AAAAMMDD>-<uuid>` (la fecha permite ver cuándo se autorizó).
         */
        fun makeKeyComment(
            id: UUID = UUID.randomUUID(),
            date: LocalDate = LocalDate.now(ZoneId.systemDefault()),
        ): String = "${AuthorizedDeviceKey.COMMENT_PREFIX}${AuthorizedDeviceKey.dateStamp(date)}-${id.toString().lowercase()}"

        fun base64UrlEncode(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

        /** Base64url sin relleno; `null` si no es válido (incluida una longitud imposible). */
        fun base64UrlDecode(text: String): ByteArray? {
            val standard = text.replace('-', '+').replace('_', '/')
            val remainder = standard.length % 4
            val padded = if (remainder > 0) standard + "=".repeat(4 - remainder) else standard
            return try {
                Base64.getDecoder().decode(padded)
            } catch (_: IllegalArgumentException) {
                null
            }
        }

        private fun decodePayload(json: ByteArray): Payload? = try {
            JSON.decodeFromString(Payload.serializer(), json.decodeToString(throwOnInvalidSequence = true))
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        } catch (_: CharacterCodingException) {
            null
        }

        private fun parseUri(text: String): URI? = try {
            URI(text)
        } catch (_: URISyntaxException) {
            null
        }

        /** Valor del primer parámetro [name] de la query, con el `%XX` decodificado (sin `+` → espacio). */
        private fun queryValue(rawQuery: String?, name: String): String? =
            rawQuery?.split('&')
                ?.map { it.split('=', limit = 2) }
                ?.firstOrNull { percentDecode(it[0]) == name }
                ?.let { percentDecode(it.getOrElse(1) { "" }) }

        private fun percentDecode(text: String): String {
            if ('%' !in text) return text
            val bytes = ByteArrayOutputStream()
            var i = 0
            while (i < text.length) {
                val hex = if (text[i] == '%' && i + 2 < text.length) hexByte(text.substring(i + 1, i + 3)) else null
                if (hex != null) {
                    bytes.write(hex)
                    i += 3
                } else {
                    bytes.write(text[i].toString().toByteArray(Charsets.UTF_8))
                    i += 1
                }
            }
            return bytes.toString(Charsets.UTF_8)
        }

        private fun hexByte(pair: String): Int? =
            if (pair.all { it in '0'..'9' || it.lowercaseChar() in 'a'..'f' }) pair.toInt(16) else null

        private fun hasControlCharacters(text: String): Boolean =
            text.codePoints().anyMatch {
                val type = Character.getType(it)
                type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()
            }
    }
}
