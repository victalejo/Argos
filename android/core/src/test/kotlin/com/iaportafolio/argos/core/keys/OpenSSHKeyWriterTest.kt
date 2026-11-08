package com.iaportafolio.argos.core.keys

import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Serialización OpenSSH de claves Ed25519. Interoperabilidad comprobada de dos formas:
 * vectores fijos generados por el `OpenSSHKeyWriter.swift` del Mac (CryptoKit) y el
 * `ssh-keygen` real del sistema.
 */
class OpenSSHKeyWriterTest {

    @Test
    fun `la clave privada generada se vuelve a leer y es la misma`() {
        val key = Ed25519Key.generate()
        val pem = OpenSSHKeyWriter.privateKeyPem(key, comment = "argos-iphone-x")
        assertTrue(pem.startsWith(OpenSSHKeyWriter.PEM_HEADER))
        val parsed = OpenSSHTestReader.read(pem)
        assertContentEquals(key.seed, parsed.seed)
        assertContentEquals(key.publicKey, parsed.publicKey)
        assertEquals("argos-iphone-x", parsed.comment)
        assertEquals(0, parsed.privateSectionSize % 8)
    }

    @Test
    fun `la clave privada pasa la validacion de claves importadas`() {
        val pem = OpenSSHKeyWriter.privateKeyPem(Ed25519Key.generate(), comment = "c")
        assertEquals(pem, ImportedKeyValidation.validate(pem.toByteArray()))
    }

    @Test
    fun `la linea de authorized_keys tiene tipo blob y comentario`() {
        val key = Ed25519Key.generate()
        val parts = OpenSSHKeyWriter.authorizedKeyLine(key.publicKey, comment = "argos-iphone-x").split(" ")
        assertEquals(3, parts.size)
        assertEquals("ssh-ed25519", parts[0])
        assertEquals("argos-iphone-x", parts[2])
        val blob = Base64.getDecoder().decode(parts[1])
        // string "ssh-ed25519" (4+11) + string <32 bytes> (4+32)
        assertEquals(51, blob.size)
        assertContentEquals(key.publicKey, blob.copyOfRange(19, 51))
    }

    @Test
    fun `la semilla deriva la misma clave publica que CryptoKit`() {
        assertEquals(SwiftVectors.PUBLIC_KEY_BASE64, Base64.getEncoder().encodeToString(SwiftVectors.key.publicKey))
    }

    @Test
    fun `los bytes de la linea publica son identicos a los del Mac`() {
        assertEquals(SwiftVectors.AUTHORIZED_LINE, OpenSSHKeyWriter.authorizedKeyLine(SwiftVectors.key.publicKey, SwiftVectors.COMMENT))
    }

    @Test
    fun `los bytes de la clave privada son identicos a los del Mac`() {
        val pem = OpenSSHKeyWriter.privateKeyPem(SwiftVectors.key, SwiftVectors.COMMENT, checkInt = SwiftVectors.CHECK_INT)
        assertEquals(SwiftVectors.PRIVATE_PEM, pem)
    }

    @Test
    fun `ssh-keygen acepta la clave y deriva la misma linea publica y huella`(@TempDir dir: Path) {
        val sshKeygen = listOf("/usr/bin/ssh-keygen", "/usr/local/bin/ssh-keygen", "/opt/homebrew/bin/ssh-keygen")
            .firstOrNull { File(it).canExecute() }
        assumeTrue(sshKeygen != null, "ssh-keygen no está instalado")

        val key = Ed25519Key.generate()
        val file = dir.resolve("id_argos")
        Files.writeString(file, OpenSSHKeyWriter.privateKeyPem(key, comment = "argos-iphone-test"))
        Files.setPosixFilePermissions(file, PosixFilePermissions.fromString("rw-------"))

        val publicLine = run(listOf(requireNotNull(sshKeygen), "-y", "-f", file.toString()))
        val expected = OpenSSHKeyWriter.authorizedKeyLine(key.publicKey, comment = "argos-iphone-test")
        assertEquals(expected.substringBeforeLast(' '), publicLine.trim().split(" ").take(2).joinToString(" "))

        val fingerprintLine = run(listOf(sshKeygen, "-l", "-E", "sha256", "-f", file.toString()))
        val fingerprint = AuthorizedDeviceKey.fingerprintOfBlob(OpenSSHKeyWriter.publicKeyBlob(key.publicKey))
        assertTrue(fingerprintLine.contains(fingerprint), "ssh-keygen: $fingerprintLine, esperado $fingerprint")
    }

    private fun run(command: List<String>): String {
        val process = ProcessBuilder(command).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        assertTrue(process.waitFor(30, TimeUnit.SECONDS), "ssh-keygen no terminó")
        assertEquals(0, process.exitValue(), output)
        return output
    }
}

/** Vectores generados con el `OpenSSHKeyWriter.swift` y `ServerTransfer.swift` reales (CryptoKit). */
internal object SwiftVectors {
    val SEED = ByteArray(32) { it.toByte() }
    val key: Ed25519Key = Ed25519Key.fromSeed(SEED)
    const val CHECK_INT = 0x01020304
    const val COMMENT = "argos-iphone-20261107-0f3c2a9e-1111-2222-3333-444455556666"
    const val PUBLIC_KEY_BASE64 = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
    const val AUTHORIZED_LINE =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4 $COMMENT"
    const val PRIVATE_PEM = "-----BEGIN OPENSSH PRIVATE KEY-----\n" +
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz\n" +
        "c2gtZWQyNTUxOQAAACADoQe/884Qvh1w3RjnS8CZZ+TWMJulDV8d3IZkElUxuAAA\n" +
        "AMABAgMEAQIDBAAAAAtzc2gtZWQyNTUxOQAAACADoQe/884Qvh1w3RjnS8CZZ+TW\n" +
        "MJulDV8d3IZkElUxuAAAAEAAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0e\n" +
        "HwOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4AAAAOmFyZ29zLWlwaG9u\n" +
        "ZS0yMDI2MTEwNy0wZjNjMmE5ZS0xMTExLTIyMjItMzMzMy00NDQ0NTU1NTY2NjYB\n" +
        "AgM=\n" +
        "-----END OPENSSH PRIVATE KEY-----\n"

    /** `JSONEncoder` de Swift: orden de claves aleatorio y `/` escapado como `\/`. */
    const val URL_WITH_FINGERPRINT = "argos://add-server?d=eyJ1IjoidmljdG9yIiwiayI6IkFBRUNBd1FGQmdjSUNRb0xEQTBPRHhBUkVo" +
        "TVVGUllYR0JrYUd4d2RIaDgiLCJwIjoyMjIyLCJ2IjoxLCJoIjoiZGV2LmV4YW1wbGUuY29tIiwibiI6IlNlcnZpZG9yIMOxIiwidCI6MTgwMDAw" +
        "MDAwMCwiYyI6ImFyZ29zLWlwaG9uZS0yMDI2MTEwNy0wZjNjMmE5ZS0xMTExLTIyMjItMzMzMy00NDQ0NTU1NTY2NjYiLCJmIjoiU0hBMjU2Ok1W" +
        "dmtqXC84Z0dsMzl5M3FPdzFJcTQ4bzFaNFQzRlBKN1ZoMkNPNDM4QUVBIn0"
    const val URL_WITHOUT_FINGERPRINT = "argos://add-server?d=eyJoIjoiZGV2LmV4YW1wbGUuY29tIiwidSI6InZpY3RvciIsIm4iOiJT" +
        "ZXJ2aWRvciDDsSIsImMiOiJhcmdvcy1pcGhvbmUtMjAyNjExMDctMGYzYzJhOWUtMTExMS0yMjIyLTMzMzMtNDQ0NDU1NTU2NjY2IiwicCI6MjIy" +
        "MiwidiI6MSwiayI6IkFBRUNBd1FGQmdjSUNRb0xEQTBPRHhBUkVoTVVGUllYR0JrYUd4d2RIaDgiLCJ0IjoxODAwMDAwMDAwfQ"
    const val URL_FINGERPRINT = "SHA256:MVvkj/8gGl39y3qOw1Iq48o1Z4T3FPJ7Vh2CO438AEA"
    const val URL_CREATED_AT = 1_800_000_000L
}

/** Lector mínimo de `openssh-key-v1` sin cifrar, solo para verificar el writer en tests. */
internal object OpenSSHTestReader {
    class Parsed(val seed: ByteArray, val publicKey: ByteArray, val comment: String, val privateSectionSize: Int)

    fun read(pem: String): Parsed {
        val base64 = pem.lines().filter { it.isNotEmpty() && !it.startsWith("-----") }.joinToString("")
        val body = ByteBuffer.wrap(Base64.getDecoder().decode(base64))
        val magic = ByteArray(15).also(body::get)
        check(String(magic, 0, 14) == "openssh-key-v1" && magic[14] == 0.toByte())
        check(body.string().decodeToString() == "none")
        check(body.string().decodeToString() == "none")
        check(body.string().isEmpty())
        check(body.int == 1)
        body.string() // blob público
        val section = body.string()
        val private = ByteBuffer.wrap(section)
        check(private.int == private.int) // checkInt repetido
        check(private.string().decodeToString() == OpenSSHKeyWriter.KEY_TYPE)
        val publicKey = private.string()
        val secret = private.string()
        val comment = private.string().decodeToString()
        check(secret.copyOfRange(32, 64).contentEquals(publicKey))
        return Parsed(secret.copyOfRange(0, 32), publicKey, comment, section.size)
    }

    private fun ByteBuffer.string(): ByteArray = ByteArray(int).also(::get)
}
