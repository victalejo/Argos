package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.core.keys.ImportedKeyValidation
import com.iaportafolio.argos.core.keys.ServerTransfer
import com.iaportafolio.argos.testing.FailingSecretStore
import com.iaportafolio.argos.testing.InMemorySecretStore
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.QR_FINGERPRINT
import com.iaportafolio.argos.testing.RacingTrustStore
import com.iaportafolio.argos.testing.SoftwareCipher
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.transfer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ServerImporterTest {

    private val repository = InMemoryServerRepository()
    private val secrets = InMemorySecretStore()
    private val hostKeys = InMemoryTrustStore()
    private val importer = ServerImporter(repository, secrets, hostKeys, newId = { "NEW" })

    @Test
    fun `crea un servidor con clave sin passphrase y guarda la clave del QR`() = runTest {
        val qr = transfer(host = "dev.example.com", port = 2222)
        val server = importer.import(qr)

        assertEquals("NEW", server.id)
        assertEquals("dev", server.name)
        assertEquals("dev.example.com", server.host)
        assertEquals(2222, server.port)
        assertEquals("victor", server.username)
        assertEquals(AuthMethod.KEY, server.authMethod)
        assertFalse(server.requiresPassphrase)
        assertEquals("", server.privateKeyPath)
        assertEquals(listOf(server), repository.servers.value)
        val key = secrets.values["NEW" to SecretKind.PRIVATE_KEY]
        // La clave guardada es una OpenSSH válida y con el comentario del Mac.
        assertEquals(key, key?.let { ImportedKeyValidation.validate(it.toByteArray()) })
        assertTrue(key.orEmpty().startsWith("-----BEGIN OPENSSH PRIVATE KEY-----"))
        assertNull(secrets.values["NEW" to SecretKind.PASSPHRASE])
    }

    @Test
    fun `la clave se guarda cifrada en disco, nunca en claro`(@TempDir dir: File) = runTest {
        val encrypted = EncryptedSecretStore(dir, SoftwareCipher())
        val qr = transfer()
        val pem = qr.privateKeyPem()
        ServerImporter(repository, encrypted, hostKeys, newId = { "NEW" }).import(qr)

        val files = dir.listFiles().orEmpty()
        assertEquals(1, files.size)
        val raw = files.single().readBytes().decodeToString()
        assertFalse("OPENSSH" in raw)
        assertFalse(pem.lines()[1] in raw)
        assertTrue(encrypted.read("NEW", SecretKind.PRIVATE_KEY).orEmpty().startsWith("-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    @Test
    fun `guarda la huella del QR si el endpoint no tenía ninguna`() = runTest {
        importer.import(transfer(port = 2222))
        assertEquals(mapOf("dev.example.com:2222" to QR_FINGERPRINT), hostKeys.known)
    }

    @Test
    fun `si ya había la misma huella no cambia nada`() = runTest {
        hostKeys.known["dev.example.com:22"] = QR_FINGERPRINT
        importer.import(transfer())
        assertEquals(mapOf("dev.example.com:22" to QR_FINGERPRINT), hostKeys.known)
        assertEquals(1, repository.servers.value.size)
    }

    @Test
    fun `sin huella en el QR no confía en nada (TOFU en la primera conexión)`() = runTest {
        importer.import(transfer(fingerprint = null))
        assertTrue(hostKeys.known.isEmpty())
        assertEquals(1, repository.servers.value.size)
    }

    @Test
    fun `una huella distinta ya confiada bloquea sin escribir nada`() = runTest {
        hostKeys.known["dev.example.com:22"] = "SHA256:otra"
        val error = assertFailsWith<ServerTransfer.HostKeyConflictException> { importer.import(transfer()) }
        assertEquals("dev.example.com:22", error.endpoint)
        assertTrue(repository.servers.value.isEmpty())
        assertTrue(secrets.values.isEmpty())
        assertEquals(mapOf("dev.example.com:22" to "SHA256:otra"), hostKeys.known)
    }

    @Test
    fun `vuelve a comprobar el conflicto al guardar la huella y deshace la clave`() = runTest {
        // Entre la primera comprobación y guardar la huella, otra conexión confió en otra.
        val racing = RacingTrustStore(afterFirstRead = "dev.example.com:22" to "SHA256:otra")
        val importer = ServerImporter(repository, secrets, racing, newId = { "NEW" })

        assertFailsWith<ServerTransfer.HostKeyConflictException> { importer.import(transfer()) }
        assertTrue(repository.servers.value.isEmpty())
        assertTrue(secrets.values.isEmpty())
        assertEquals(listOf("NEW"), secrets.deletedAll)
        assertEquals(mapOf("dev.example.com:22" to "SHA256:otra"), racing.known)
    }

    @Test
    fun `si falla guardar la clave no queda el servidor a medias`() = runTest {
        val failing = FailingSecretStore()
        val importer = ServerImporter(repository, failing, hostKeys, newId = { "NEW" })

        assertFailsWith<IOException> { importer.import(transfer()) }
        assertTrue(repository.servers.value.isEmpty())
        assertTrue(failing.values.isEmpty())
        assertTrue(hostKeys.known.isEmpty())
    }

    @Test
    fun `si falla guardar el servidor se borran la clave y la huella nueva`() = runTest {
        repository.failWrites = IOException("sin espacio")

        assertFailsWith<IOException> { importer.import(transfer()) }
        assertTrue(repository.servers.value.isEmpty())
        assertTrue(secrets.values.isEmpty())
        assertEquals(listOf("NEW"), secrets.deletedAll)
        assertTrue(hostKeys.known.isEmpty())
    }

    @Test
    fun `si falla guardar el servidor no se olvida una huella que ya estaba`() = runTest {
        hostKeys.known["dev.example.com:22"] = QR_FINGERPRINT
        repository.failWrites = IOException("sin espacio")

        assertFailsWith<IOException> { importer.import(transfer()) }
        assertEquals(mapOf("dev.example.com:22" to QR_FINGERPRINT), hostKeys.known)
    }

    @Test
    fun `una cancelación también deshace lo escrito y se relanza`() = runTest {
        repository.failWrites = CancellationException("cancelado")

        assertFailsWith<CancellationException> { importer.import(transfer()) }
        assertTrue(secrets.values.isEmpty())
        assertTrue(hostKeys.known.isEmpty())
    }

    @Test
    fun `un duplicado se añade como otro servidor`() = runTest {
        repository.upsert(server(id = "OLD", host = "dev.example.com"))
        importer.import(transfer())
        assertEquals(listOf("OLD", "NEW"), repository.servers.value.map { it.id })
    }
}
