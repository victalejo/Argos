package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.keys.Ed25519Key
import com.iaportafolio.argos.core.keys.OpenSSHKeyWriter
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path
import java.security.Security
import kotlin.io.path.readText
import kotlin.io.path.writeText
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** Conexión, autenticación y TOFU contra un servidor SSH real embebido (MINA SSHD). */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjConnectionTest {

    private lateinit var workDir: Path

    private lateinit var server: EmbeddedSshServer
    private lateinit var plainKeyPem: String
    private lateinit var encryptedKeyPem: String
    private val connector = SshjConnector()
    private val localUser = System.getProperty("user.name")

    @BeforeAll
    fun startServer(@TempDir dir: Path) {
        workDir = dir
        SshjConnector.installSecurityProvider()
        val plainKey = Ed25519Key.generate()
        plainKeyPem = OpenSSHKeyWriter.privateKeyPem(plainKey, "sin-passphrase")

        // Clave con passphrase generada por OpenSSH (bcrypt + aes256-ctr), como las del usuario.
        val encryptedFile = workDir.resolve("cifrada")
        runProcess("ssh-keygen", "-q", "-t", "ed25519", "-N", PASSPHRASE, "-C", "con-passphrase", "-f", encryptedFile.toString())
        encryptedKeyPem = encryptedFile.readText()

        server = EmbeddedSshServer.start(
            workDir = Files.createDirectories(workDir.resolve("server")),
            password = PASSWORD,
            authorizedKeys = listOf(
                OpenSSHKeyWriter.authorizedKeyLine(plainKey.publicKey, "sin-passphrase"),
                workDir.resolve("cifrada.pub").readText().trim(),
            ),
        )
    }

    @AfterAll
    fun stopServer() {
        server.close()
    }

    private fun service(credentials: SSHCredentials, trust: InMemoryTrustStore = InMemoryTrustStore()) =
        connector.service(testServer(server.port), credentials, trust) as SshjSSHService

    @Test
    fun `conecta con contraseña y ejecuta comandos`() = runBlocking<Unit> {
        val service = service(SSHCredentials.Password(PASSWORD))
        assertEquals(localUser, service.testConnection())
        service.disconnect()
    }

    @Test
    fun `conecta con clave Ed25519 sin passphrase leída del contenido PEM`() = runBlocking<Unit> {
        val service = service(SSHCredentials.PrivateKey(plainKeyPem, passphrase = null))
        assertEquals(localUser, service.testConnection())
        service.disconnect()
    }

    @Test
    fun `conecta con clave Ed25519 cifrada con passphrase`() = runBlocking<Unit> {
        val service = service(SSHCredentials.PrivateKey(encryptedKeyPem, PASSPHRASE))
        assertEquals(localUser, service.testConnection())
        service.disconnect()
    }

    @Test
    fun `passphrase incorrecta da KeyParseFailed`() {
        val service = service(SSHCredentials.PrivateKey(encryptedKeyPem, "otra"))
        assertFailsWith<SSHServiceError.KeyParseFailed> { runBlocking { service.testConnection() } }
    }

    @Test
    fun `clave que no es OpenSSH da KeyParseFailed`() {
        val service = service(SSHCredentials.PrivateKey("no es una clave", passphrase = null))
        assertFailsWith<SSHServiceError.KeyParseFailed> { runBlocking { service.testConnection() } }
    }

    @Test
    fun `contraseña incorrecta da un error de autenticación claro`() {
        val service = service(SSHCredentials.Password("mala"))
        val error = assertFailsWith<SshConnectionException.AuthenticationFailed> {
            runBlocking { service.testConnection() }
        }
        assertContains(error.message.orEmpty(), "rechazó la autenticación")
    }

    @Test
    fun `clave no autorizada da un error de autenticación`() {
        val stranger = OpenSSHKeyWriter.privateKeyPem(Ed25519Key.generate(), "extraña")
        val service = service(SSHCredentials.PrivateKey(stranger, passphrase = null))
        assertFailsWith<SshConnectionException.AuthenticationFailed> { runBlocking { service.testConnection() } }
    }

    @Test
    fun `puerto cerrado da error de servidor inalcanzable`() {
        val closedPort = ServerSocket(0).use { it.localPort }
        val service = connector.service(testServer(closedPort), SSHCredentials.Password(PASSWORD), InMemoryTrustStore())
        assertFailsWith<SshConnectionException.Unreachable> { runBlocking { service.listSessions() } }
    }

    @Test
    fun `TOFU guarda en la primera conexión la misma huella que ssh-keygen`() = runBlocking<Unit> {
        val trust = InMemoryTrustStore()
        val service = service(SSHCredentials.Password(PASSWORD), trust)
        service.testConnection()
        service.disconnect()

        val hostPub = workDir.resolve("host.pub").apply { writeText(server.hostPublicKeyLine + "\n") }
        val expected = sshKeygenFingerprint(hostPub)
        val endpoint = "127.0.0.1:${server.port}"
        assertEquals(mapOf(endpoint to expected), trust.entries)
        assertEquals(server.hostFingerprint, expected)
    }

    @Test
    fun `huella confiada distinta aborta con HostKeyMismatchException`() {
        val endpoint = "127.0.0.1:${server.port}"
        val stored = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        val trust = InMemoryTrustStore(mapOf(endpoint to stored))
        val service = service(SSHCredentials.Password(PASSWORD), trust)

        val error = assertFailsWith<HostKeyMismatchException> { runBlocking { service.testConnection() } }
        assertEquals(endpoint, error.endpoint)
        assertEquals(stored, error.storedFingerprint)
        assertEquals(server.hostFingerprint, error.presentedFingerprint)
        assertEquals(stored, trust.trustedFingerprint(endpoint), "no debe sobrescribir la huella confiada")
    }

    @Test
    fun `tras olvidar la huella vuelve a confiar`() = runBlocking<Unit> {
        val endpoint = "127.0.0.1:${server.port}"
        val trust = InMemoryTrustStore(mapOf(endpoint to "SHA256:vieja"))
        trust.forget(endpoint)
        val service = service(SSHCredentials.Password(PASSWORD), trust)
        service.testConnection()
        service.disconnect()
        assertEquals(server.hostFingerprint, trust.trustedFingerprint(endpoint))
    }

    @Test
    fun `disconnect es idempotente y la siguiente operación reconecta`() = runBlocking<Unit> {
        val service = service(SSHCredentials.Password(PASSWORD))
        service.disconnect()
        assertEquals(localUser, service.testConnection())
        service.disconnect()
        service.disconnect()
        assertEquals(localUser, service.testConnection())
        service.disconnect()
    }

    @Test
    fun `comandos en paralelo comparten una sola conexión`() = runBlocking<Unit> {
        val service = service(SSHCredentials.Password(PASSWORD))
        val outputs = (1..8).map { index ->
            async(Dispatchers.IO) { service.runAgentScript("echo $index") }
        }.map { it.await().trim() }
        assertEquals((1..8).map(Int::toString), outputs)
        service.disconnect()
    }

    @Test
    fun `installSecurityProvider deja BouncyCastle completo como primer proveedor`() {
        SshjConnector.installSecurityProvider()
        SshjConnector.installSecurityProvider()
        val first = Security.getProviders().first()
        assertEquals("BC", first.name)
        assertEquals(1, Security.getProviders().count { it.name == "BC" })
    }

    private companion object {
        const val PASSWORD = "contraseña-de-prueba"
        const val PASSPHRASE = "frase secreta"
    }
}
