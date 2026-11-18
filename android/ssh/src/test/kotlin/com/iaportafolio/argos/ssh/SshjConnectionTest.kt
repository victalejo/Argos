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
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import com.iaportafolio.argos.core.ConnectionProbeResult
import kotlin.time.Duration.Companion.seconds
import kotlin.test.assertFalse
import kotlin.test.assertTrue
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

    // MARK: Canales

    private fun connection() = SshjConnection(
        testServer(server.port),
        SSHCredentials.Password(PASSWORD),
        InMemoryTrustStore(),
        SshjConnector.Settings(),
    )

    /** Espera a que el servidor cierre los canales de más (los abandonados se cierran solos). */
    private suspend fun awaitChannelsAtMost(expected: Int) {
        withTimeout(CHANNEL_SETTLE_MILLIS) { while (server.openChannels > expected) delay(POLL_MILLIS) }
    }

    /**
     * Antes, cancelar una captura mientras sshj abría su canal (`CHANNEL_OPEN` enviado, esperando
     * la confirmación) dejaba el canal abierto en el servidor sin dueño: tras unos cuantos sondeos
     * cancelados se agotaba `MaxSessions` y todo fallaba con «open failed».
     */
    @Test
    fun `cancelar capturas a mitad de abrir el canal no deja canales huérfanos`() = runBlocking<Unit> {
        val connection = connection()
        val service = SshjSSHService(connection)
        try {
            assertEquals(localUser, service.testConnection())
            val baseline = server.openChannels
            server.channelOpenDelayMillis = OPEN_DELAY_MILLIS
            try {
                repeat(EmbeddedSshServer.MAX_CHANNELS_PER_CONNECTION + 2) {
                    val job = launch(Dispatchers.IO) { service.runAgentScript("echo hola") }
                    delay(OPEN_DELAY_MILLIS / 3) // en plena apertura del canal
                    job.cancelAndJoin()
                }
            } finally {
                server.channelOpenDelayMillis = 0
            }
            awaitChannelsAtMost(baseline)

            // Siguen cabiendo todos los canales que admite la conexión.
            val ssh = connection.connectedClient()
            val sessions = (1..EmbeddedSshServer.MAX_CHANNELS_PER_CONNECTION).map { ssh.startSession() }
            sessions.forEach { it.close() }
            assertEquals("hola", service.runAgentScript("echo hola").trim())
        } finally {
            server.channelOpenDelayMillis = 0
            service.disconnect()
        }
    }

    @Test
    fun `más capturas a la vez que MaxSessions esperan turno en vez de fallar`() = runBlocking<Unit> {
        val service = service(SSHCredentials.Password(PASSWORD))
        try {
            val count = EmbeddedSshServer.MAX_CHANNELS_PER_CONNECTION * 2
            val outputs = (1..count).map { index ->
                async(Dispatchers.IO) { service.runAgentScript("sleep 0.3; echo $index") }
            }.map { it.await().trim() }
            assertEquals((1..count).map(Int::toString), outputs)
        } finally {
            service.disconnect()
        }
    }

    @Test
    fun `una captura que no termina caduca y libera su canal`() = runBlocking<Unit> {
        val connection = connection()
        try {
            connection.capture("true")
            val baseline = server.openChannels
            val started = System.nanoTime()
            val error = assertFailsWith<SshCommandTimeoutException> { connection.capture("sleep 30", 1.seconds) }
            assertTrue(System.nanoTime() - started < 10.seconds.inWholeNanoseconds, "debe caducar pronto")
            assertContains(error.message.orEmpty(), "no respondió en 1 s")
            awaitChannelsAtMost(baseline)
            assertEquals(0, connection.capture("true").exitCode)
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun `si el servidor rechaza canales una y otra vez se recicla la conexión`() = runBlocking<Unit> {
        val connection = connection()
        try {
            val ssh = connection.connectedClient()
            // Ocupa todos los canales de la conexión compartida.
            val held = (1..EmbeddedSshServer.MAX_CHANNELS_PER_CONNECTION).map { ssh.startSession() }
            val error = assertFailsWith<SshChannelRejectedException> { connection.capture("true") }
            assertContains(error.message.orEmpty(), "rechazó abrir un canal")
            assertFalse(ssh.isConnected, "la conexión saturada debe cerrarse")
            held.forEach { runCatching { it.close() } }
            // La siguiente operación abre una conexión nueva y funciona.
            assertEquals(0, connection.capture("true").exitCode)
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun `la sonda distingue sin conexión, viva y colgada`() = runBlocking<Unit> {
        val connection = connection()
        try {
            assertEquals(ConnectionProbeResult.NOT_CONNECTED, connection.probe())
            val first = connection.connectedClient()
            assertEquals(ConnectionProbeResult.ALIVE, connection.probe())

            // El servidor deja de responder a canales nuevos: la sonda no espera más que su plazo.
            server.channelOpenDelayMillis = HUNG_DELAY_MILLIS
            val started = System.nanoTime()
            try {
                assertEquals(ConnectionProbeResult.RECYCLED, connection.probe(1.seconds))
            } finally {
                server.channelOpenDelayMillis = 0
            }
            assertTrue(System.nanoTime() - started < 4.seconds.inWholeNanoseconds, "la sonda debe respetar su plazo")
            assertTrue(first !== connection.connectedClient(), "tras reciclar se abre otra conexión")
            assertEquals(ConnectionProbeResult.ALIVE, connection.probe())
        } finally {
            server.channelOpenDelayMillis = 0
            connection.disconnect()
        }
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
        const val OPEN_DELAY_MILLIS = 300L
        const val HUNG_DELAY_MILLIS = 3_000L
        const val CHANNEL_SETTLE_MILLIS = 15_000L
        const val POLL_MILLIS = 50L
    }
}
