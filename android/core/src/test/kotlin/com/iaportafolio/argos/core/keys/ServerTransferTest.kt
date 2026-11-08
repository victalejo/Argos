package com.iaportafolio.argos.core.keys

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.time.Instant
import java.time.LocalDate
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/ServerTransferTests.swift` (enlace del QR y comandos de authorized_keys). */
class ServerTransferTest {

    private val now: Instant = Instant.ofEpochSecond(1_800_000_000)

    private fun sample(createdAt: Instant = now) = ServerTransfer(
        name = "dev", host = "dev.example.com", port = 2222, username = "victor",
        keySeed = ByteArray(32) { 7 },
        keyComment = "argos-iphone-abc",
        hostKeyFingerprint = "SHA256:abcdef",
        createdAt = createdAt,
    )

    private fun decodeError(text: String, at: Instant = now): ServerTransfer.DecodeError =
        assertFailsWith<ServerTransfer.DecodeException> { ServerTransfer.decode(text, at) }.error

    // Enlace del QR

    @Test
    fun `el enlace se lee igual que se escribio`() {
        val transfer = sample()
        val url = transfer.urlString()
        assertTrue(url.startsWith("argos://add-server?d="))
        assertEquals(transfer, ServerTransfer.decode(url, now))
    }

    @Test
    fun `la semilla del QR produce la misma clave`() {
        val key = Ed25519Key.generate()
        val transfer = sample().copy(keySeed = key.seed)
        assertContentEquals(key.publicKey, OpenSSHTestReader.read(transfer.privateKeyPem()).publicKey)
    }

    @Test
    fun `sin huella de host key tambien es valido`() {
        val transfer = sample().copy(hostKeyFingerprint = null)
        val url = transfer.urlString()
        assertFalse(String(ServerTransfer.base64UrlDecode(url.substringAfter("d=")) ?: ByteArray(0)).contains("\"f\""))
        assertEquals(transfer, ServerTransfer.decode(url, now))
    }

    @Test
    fun `caduca a los 5 minutos`() {
        val url = sample().urlString()
        ServerTransfer.decode(url, now.plusSeconds(299))
        assertEquals(ServerTransfer.DecodeError.EXPIRED, decodeError(url, now.plusSeconds(301)))
    }

    @Test
    fun `tolera un reloj algo atrasado pero no demasiado`() {
        val url = sample().urlString()
        ServerTransfer.decode(url, now.minusSeconds(30))
        assertEquals(ServerTransfer.DecodeError.EXPIRED, decodeError(url, now.minusSeconds(120)))
    }

    @ParameterizedTest
    @ValueSource(strings = ["https://example.com", "argos://otra-cosa?d=x", "hola", "", "argos://add server"])
    fun `rechaza QR que no son de Argos`(text: String) {
        assertEquals(ServerTransfer.DecodeError.NOT_ARGOS_CODE, decodeError(text))
    }

    @ParameterizedTest
    @ValueSource(strings = ["argos://add-server", "argos://add-server?d=no-es-base64!", "argos://add-server?d=e30"])
    fun `rechaza contenido danado`(text: String) {
        assertEquals(ServerTransfer.DecodeError.MALFORMED, decodeError(text))
    }

    @Test
    fun `rechaza otra version`() {
        val json = """{"v":2,"n":"a","h":"b","p":22,"u":"c","k":"","c":"d","t":1800000000}"""
        val url = "argos://add-server?d=" + ServerTransfer.base64UrlEncode(json.toByteArray())
        assertEquals(ServerTransfer.DecodeError.UNSUPPORTED_VERSION, decodeError(url))
    }

    @Test
    fun `rechaza datos de servidor no validos`() {
        val mutations: List<(ServerTransfer) -> ServerTransfer> = listOf(
            { it.copy(host = "") },
            { it.copy(host = "a b") },
            { it.copy(host = "-oProxyCommand=x") },
            { it.copy(username = "x\ny") },
            { it.copy(name = "a​b") }, // carácter de formato (Cf)
            { it.copy(port = 0) },
            { it.copy(port = 70000) },
            { it.copy(keySeed = ByteArray(16)) },
            { it.copy(keyComment = "dos palabras") },
            { it.copy(hostKeyFingerprint = "MD5:aa") },
        )
        for (mutate in mutations) {
            val url = mutate(sample()).urlString()
            assertEquals(ServerTransfer.DecodeError.INVALID_DATA, decodeError(url), url)
        }
    }

    @Test
    fun `comentario de clave unico sin espacios y con la fecha`() {
        val comment = ServerTransfer.makeKeyComment()
        assertTrue(comment.startsWith("argos-iphone-"))
        assertFalse(comment.contains(" "))
        assertNotEquals(comment, ServerTransfer.makeKeyComment())

        val id = UUID.fromString("0F3C2A9E-1111-2222-3333-444455556666")
        val date = requireNotNull(AuthorizedDeviceKey.dateFromStamp("20261107"))
        assertEquals(
            "argos-iphone-20261107-0f3c2a9e-1111-2222-3333-444455556666",
            ServerTransfer.makeKeyComment(id, date),
        )
    }

    @Test
    fun `un QR con otra huella para un servidor conocido es conflicto`() {
        val transfer = sample().copy(hostKeyFingerprint = "SHA256:falsa")
        assertFalse(transfer.conflictsWithTrustedHostKey(trustedFingerprint = null)) // desconocido
        assertTrue(transfer.conflictsWithTrustedHostKey(trustedFingerprint = "SHA256:real"))
        assertFalse(transfer.copy(hostKeyFingerprint = "SHA256:real").conflictsWithTrustedHostKey("SHA256:real"))
        assertFalse(transfer.copy(hostKeyFingerprint = null).conflictsWithTrustedHostKey("SHA256:real"))
    }

    @Test
    fun `la semilla no aparece en toString y no se puede mutar desde fuera`() {
        val seed = ByteArray(32) { 9 }
        val transfer = sample().copy(keySeed = seed)
        seed[0] = 0
        transfer.keySeed[1] = 0
        assertContentEquals(ByteArray(32) { 9 }, transfer.keySeed)
        assertTrue("<oculta>" in transfer.toString())
    }

    // Interoperabilidad con el Mac

    @Test
    fun `decodifica un enlace generado por el Mac`() {
        val transfer = ServerTransfer.decode(SwiftVectors.URL_WITH_FINGERPRINT, Instant.ofEpochSecond(SwiftVectors.URL_CREATED_AT + 10))
        assertEquals("Servidor ñ", transfer.name)
        assertEquals("dev.example.com", transfer.host)
        assertEquals(2222, transfer.port)
        assertEquals("victor", transfer.username)
        assertEquals(SwiftVectors.COMMENT, transfer.keyComment)
        assertEquals(SwiftVectors.URL_FINGERPRINT, transfer.hostKeyFingerprint)
        assertEquals(Instant.ofEpochSecond(SwiftVectors.URL_CREATED_AT), transfer.createdAt)
        assertContentEquals(SwiftVectors.SEED, transfer.keySeed)
        // La clave del QR es byte a byte la que el Mac habría escrito.
        val pem = OpenSSHKeyWriter.privateKeyPem(Ed25519Key.fromSeed(transfer.keySeed), transfer.keyComment, SwiftVectors.CHECK_INT)
        assertEquals(SwiftVectors.PRIVATE_PEM, pem)
    }

    @Test
    fun `decodifica un enlace del Mac sin huella`() {
        val transfer = ServerTransfer.decode(SwiftVectors.URL_WITHOUT_FINGERPRINT, Instant.ofEpochSecond(SwiftVectors.URL_CREATED_AT))
        assertNull(transfer.hostKeyFingerprint)
        assertContentEquals(SwiftVectors.SEED, transfer.keySeed)
    }

    @Test
    fun `base64url sin relleno ida y vuelta`() {
        for (size in 0..5) {
            val data = ByteArray(size) { (it * 37 + 250).toByte() }
            val encoded = ServerTransfer.base64UrlEncode(data)
            assertFalse(encoded.contains('=') || encoded.contains('+') || encoded.contains('/'))
            assertContentEquals(data, ServerTransfer.base64UrlDecode(encoded))
        }
        assertNull(ServerTransfer.base64UrlDecode("a"))
    }

    // authorized_keys

    @Test
    fun `autorizar anade la linea entrecomillada a authorized_keys`() {
        assertEquals(
            "umask 077 && mkdir -p \"\$HOME/.ssh\" && printf '%s\\n' 'ssh-ed25519 AAAA argos-iphone-x' >> \"\$HOME/.ssh/authorized_keys\"",
            AuthorizedKeysCommands.authorizeKey("ssh-ed25519 AAAA argos-iphone-x"),
        )
    }

    @Test
    fun `revocar filtra por el comentario y solo sobrescribe si grep fue bien`() {
        val command = AuthorizedKeysCommands.revokeKey("argos-iphone-x")
        assertTrue(command.contains("grep -vF -- ' argos-iphone-x'"))
        assertTrue(command.contains("if [ \$s -le 1 ]; then cat"))
    }

    @Test
    fun `leer authorized_keys no falla si el archivo no existe`() {
        assertTrue(AuthorizedKeysCommands.READ_AUTHORIZED_KEYS.contains("if [ -f \"\$f\" ]; then cat \"\$f\"; fi"))
    }

    @Test
    fun `fecha de ejemplo para el comentario`() {
        assertEquals("20260105", AuthorizedDeviceKey.dateStamp(LocalDate.of(2026, 1, 5)))
    }
}
