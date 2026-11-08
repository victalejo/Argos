package com.iaportafolio.argos.ssh

import com.google.zxing.BinaryBitmap
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.keys.ServerTransfer
import com.iaportafolio.argos.ssh.testing.DevTransferLink
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import javax.imageio.ImageIO
import kotlin.io.path.readText
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * De punta a punta sin Mac: el generador de testFixtures autoriza una clave nueva en el
 * `authorized_keys` del `HOME` aislado, su enlace se decodifica como lo haría la app y la
 * clave importada (`privateKeyPem`) conecta de verdad con la huella del QR ya confiada.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class ServerTransferIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private val connector = SshjConnector()
    private val localUser = System.getProperty("user.name")

    @BeforeAll
    fun startServer(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        // Sin claves fijas: solo vale lo que haya en ~/.ssh/authorized_keys del HOME aislado.
        server = EmbeddedSshServer.start(workDir = Files.createDirectories(dir.resolve("server")))
    }

    @AfterAll
    fun stopServer() {
        server.close()
    }

    private fun transfer(): ServerTransfer =
        DevTransferLink.create(home = server.home, hostFingerprint = server.hostFingerprint, port = server.port)

    @Test
    fun `la clave del enlace generado conecta con la huella del QR ya confiada`() = runBlocking<Unit> {
        val decoded = ServerTransfer.decode(transfer().urlString())
        val fingerprint = checkNotNull(decoded.hostKeyFingerprint)
        val endpoint = "${decoded.host}:${decoded.port}"
        val trust = InMemoryTrustStore(mapOf(endpoint to fingerprint))

        val service = connector.service(
            testServer(decoded.port, decoded.username),
            SSHCredentials.PrivateKey(decoded.privateKeyPem(), passphrase = null),
            trust,
        ) as SshjSSHService
        assertEquals(localUser, service.testConnection())
        service.disconnect()
        // La huella que verificó sshj es la del QR: no hubo confianza a ciegas.
        assertEquals(mapOf(endpoint to fingerprint), trust.entries)
    }

    @Test
    fun `una huella distinta a la confiada aborta la conexión`() = runBlocking<Unit> {
        val decoded = ServerTransfer.decode(transfer().urlString())
        val trust = InMemoryTrustStore(mapOf("${decoded.host}:${decoded.port}" to "SHA256:otra"))
        val service = connector.service(
            testServer(decoded.port, decoded.username),
            SSHCredentials.PrivateKey(decoded.privateKeyPem(), passphrase = null),
            trust,
        ) as SshjSSHService
        assertFailsWith<HostKeyMismatchException> { service.testConnection() }
        service.disconnect()
    }

    @Test
    fun `una clave no autorizada no entra`() = runBlocking<Unit> {
        val stranger = ServerTransfer.decode(transfer().urlString())
        // Se vacía authorized_keys: la clave del QR deja de valer al momento.
        Files.writeString(EmbeddedSshServer.authorizedKeysFile(server.home), "")
        val service = connector.service(
            testServer(stranger.port, stranger.username),
            SSHCredentials.PrivateKey(stranger.privateKeyPem(), passphrase = null),
            InMemoryTrustStore(),
        ) as SshjSSHService
        assertTrue(runCatching { service.testConnection() }.isFailure)
        service.disconnect()
    }

    @Test
    fun `authorized_keys queda con permisos de OpenSSH y una línea por clave`() {
        val first = transfer()
        val second = transfer()
        val file = EmbeddedSshServer.authorizedKeysFile(server.home)
        val lines = file.readText().lines().filter { it.isNotBlank() }
        assertTrue(lines.any { it.endsWith(first.keyComment) })
        assertTrue(lines.any { it.endsWith(second.keyComment) })
        assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(file)))
        assertEquals("rwx------", PosixFilePermissions.toString(Files.getPosixFilePermissions(file.parent)))
    }

    @Test
    fun `el PNG del QR se lee de vuelta como el mismo enlace`(@TempDir dir: Path) {
        val link = transfer().urlString()
        val png = dir.resolve("qr.png")
        DevTransferLink.writeQrPng(link, png)
        val image = checkNotNull(ImageIO.read(png.toFile()))
        val pixels = image.getRGB(0, 0, image.width, image.height, null, 0, image.width)
        val bitmap = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(image.width, image.height, pixels)))
        assertEquals(link, QRCodeReader().decode(bitmap).text)
    }

    @Test
    fun `la huella de la host key persistente coincide con la que presenta el servidor`() {
        assertEquals(server.hostFingerprint, DevTransferLink.hostFingerprint(server.home.parent.resolve("host_key")))
    }
}
