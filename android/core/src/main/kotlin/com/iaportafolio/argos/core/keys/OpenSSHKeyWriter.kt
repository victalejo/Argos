package com.iaportafolio.argos.core.keys

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.Base64

/**
 * Clave Ed25519 derivada de su semilla de 32 bytes (con BouncyCastle: Android solo trae
 * EdDSA desde API 33 y la app soporta API 29).
 */
class Ed25519Key private constructor(private val seedBytes: ByteArray, private val publicBytes: ByteArray) {

    /** Semilla (32 bytes), la `rawRepresentation` de CryptoKit. Devuelve una copia. */
    val seed: ByteArray get() = seedBytes.copyOf()

    /** Clave pública (32 bytes). Devuelve una copia. */
    val publicKey: ByteArray get() = publicBytes.copyOf()

    override fun toString(): String = "Ed25519Key(publicKey=${Base64.getEncoder().encodeToString(publicBytes)})"

    companion object {
        const val SEED_SIZE = 32

        fun fromSeed(seed: ByteArray): Ed25519Key {
            require(seed.size == SEED_SIZE) { "La semilla Ed25519 debe tener $SEED_SIZE bytes." }
            val parameters = Ed25519PrivateKeyParameters(seed, 0)
            return Ed25519Key(seed.copyOf(), parameters.generatePublicKey().encoded)
        }

        fun generate(random: SecureRandom = SecureRandom()): Ed25519Key =
            fromSeed(ByteArray(SEED_SIZE).also(random::nextBytes))
    }
}

/**
 * Serializa claves Ed25519 a los formatos de OpenSSH (port de `ArgosCore/OpenSSHKeyWriter.swift`):
 * la clave privada (`openssh-key-v1` sin cifrar) y la línea pública de `authorized_keys`.
 * Los bytes son idénticos a los que genera el Mac.
 */
object OpenSSHKeyWriter {
    const val KEY_TYPE = "ssh-ed25519"
    const val PEM_HEADER = "-----BEGIN OPENSSH PRIVATE KEY-----"
    const val PEM_FOOTER = "-----END OPENSSH PRIVATE KEY-----"

    private const val PEM_LINE_LENGTH = 64
    private const val CIPHER_BLOCK = 8
    private val random = SecureRandom()

    /** Blob público SSH: `string "ssh-ed25519"` + `string <32 bytes>`. */
    fun publicKeyBlob(publicKey: ByteArray): ByteArray = sshBuffer {
        writeString(KEY_TYPE.toByteArray(Charsets.US_ASCII))
        writeString(publicKey)
    }

    /** Línea de `authorized_keys`: `ssh-ed25519 <base64> <comentario>`. */
    fun authorizedKeyLine(publicKey: ByteArray, comment: String): String =
        "$KEY_TYPE ${Base64.getEncoder().encodeToString(publicKeyBlob(publicKey))} $comment"

    /**
     * Clave privada en formato OpenSSH sin cifrar. [checkInt] solo se fija en tests
     * (OpenSSH usa un aleatorio para detectar una passphrase incorrecta).
     */
    fun privateKeyPem(key: Ed25519Key, comment: String, checkInt: Int = random.nextInt()): String {
        val publicRaw = key.publicKey
        val unpadded = sshBuffer {
            writeUInt32(checkInt)
            writeUInt32(checkInt)
            writeString(KEY_TYPE.toByteArray(Charsets.US_ASCII))
            writeString(publicRaw)
            writeString(key.seed + publicRaw) // OpenSSH guarda los 64 bytes "semilla + pública".
            writeString(comment.toByteArray(Charsets.UTF_8))
        }
        val paddingSize = (CIPHER_BLOCK - unpadded.size % CIPHER_BLOCK) % CIPHER_BLOCK
        val privateSection = unpadded + ByteArray(paddingSize) { (it + 1).toByte() }

        val body = sshBuffer {
            write("openssh-key-v1".toByteArray(Charsets.US_ASCII))
            write(0)
            writeString("none".toByteArray(Charsets.US_ASCII)) // cifrado
            writeString("none".toByteArray(Charsets.US_ASCII)) // KDF
            writeString(ByteArray(0)) // opciones del KDF
            writeUInt32(1) // nº de claves
            writeString(publicKeyBlob(publicRaw))
            writeString(privateSection)
        }
        val base64 = Base64.getMimeEncoder(PEM_LINE_LENGTH, "\n".toByteArray()).encodeToString(body)
        return "$PEM_HEADER\n$base64\n$PEM_FOOTER\n"
    }

    // Codificación SSH (RFC 4251)

    private fun sshBuffer(block: ByteArrayOutputStream.() -> Unit): ByteArray =
        ByteArrayOutputStream().apply(block).toByteArray()

    private fun ByteArrayOutputStream.writeUInt32(value: Int) {
        write(value ushr 24)
        write(value ushr 16)
        write(value ushr 8)
        write(value)
    }

    private fun ByteArrayOutputStream.writeString(value: ByteArray) {
        writeUInt32(value.size)
        write(value)
    }
}
