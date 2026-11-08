package com.iaportafolio.argos.ssh.testing

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.iaportafolio.argos.core.keys.Ed25519Key
import com.iaportafolio.argos.core.keys.OpenSSHKeyWriter
import com.iaportafolio.argos.core.keys.ServerTransfer
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.digest.BuiltinDigests
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import java.awt.image.BufferedImage
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import java.time.Duration
import java.time.Instant
import javax.imageio.ImageIO
import kotlin.io.path.writeText

/**
 * Hace en local lo que hace «Enviar al iPhone…» del Mac, para probar la importación por QR
 * sin Mac: crea una clave Ed25519 NUEVA, la autoriza en `~/.ssh/authorized_keys` del `HOME`
 * aislado del servidor embebido y devuelve el [ServerTransfer] con la huella real del host.
 *
 * Solo para tests y desarrollo (testFixtures): nunca llega al APK.
 */
object DevTransferLink {
    private const val QR_SIZE = 600
    private const val QR_MARGIN = 2
    private const val BLACK = 0x000000
    private const val WHITE = 0xFFFFFF

    /**
     * Crea y autoriza la clave y devuelve el transfer listo para [ServerTransfer.urlString].
     *
     * @param createdAt fecha de creación del código; uno anterior a [ServerTransfer.LIFETIME]
     *   sirve para probar el aviso de caducado.
     */
    fun create(
        home: Path,
        hostFingerprint: String,
        port: Int,
        host: String = "127.0.0.1",
        username: String = "argos",
        name: String = "Argos dev (QR)",
        createdAt: Instant = Instant.now(),
    ): ServerTransfer {
        val key = Ed25519Key.generate()
        val comment = ServerTransfer.makeKeyComment()
        authorize(home, OpenSSHKeyWriter.authorizedKeyLine(key.publicKey, comment))
        return ServerTransfer(
            name = name,
            host = host,
            port = port,
            username = username,
            keySeed = key.seed,
            keyComment = comment,
            hostKeyFingerprint = hostFingerprint,
            createdAt = createdAt,
        )
    }

    /** Añade [line] a `~/.ssh/authorized_keys` con los permisos que exige OpenSSH (700/600). */
    fun authorize(home: Path, line: String) {
        val file = EmbeddedSshServer.authorizedKeysFile(home)
        val directory = Files.createDirectories(file.parent)
        Files.setPosixFilePermissions(directory, PosixFilePermissions.fromString("rwx------"))
        Files.writeString(file, line + "\n", StandardOpenOption.CREATE, StandardOpenOption.APPEND)
        Files.setPosixFilePermissions(file, PosixFilePermissions.fromString("rw-------"))
    }

    /** PNG en escala de grises del QR de [text] (corrección de errores M, como un QR de pantalla). */
    fun writeQrPng(text: String, file: Path) {
        val hints = mapOf(EncodeHintType.MARGIN to QR_MARGIN, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M)
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, QR_SIZE, QR_SIZE, hints)
        val image = BufferedImage(matrix.width, matrix.height, BufferedImage.TYPE_INT_RGB)
        for (y in 0 until matrix.height) {
            for (x in 0 until matrix.width) image.setRGB(x, y, if (matrix[x, y]) BLACK else WHITE)
        }
        Files.createDirectories(file.parent)
        check(ImageIO.write(image, "png", file.toFile())) { "No hay escritor PNG en esta JVM" }
    }

    /** Huella `SHA256:…` de la host key persistente del `devServer` (la genera si no existe). */
    fun hostFingerprint(hostKeyFile: Path): String {
        val key = SimpleGeneratorHostKeyProvider(hostKeyFile).loadKeys(null).first().public
        return KeyUtils.getFingerPrint(BuiltinDigests.sha256, key)
    }
}

private const val DEV_PORT = 2222
private const val EXPIRED_FLAG = "--caducado"

/**
 * `./gradlew :ssh:devTransferLink`: enlace y QR de prueba para el `devServer` (127.0.0.1:2222).
 *
 * Escribe `<dir>/transfer-link.txt` y `<dir>/transfer-qr.png`. Vale con el `devServer` en marcha
 * o parado: el servidor relee `authorized_keys` en cada intento. Con `--caducado` (propiedad
 * Gradle `-Pcaducado`) el código nace caducado, para probar el aviso.
 */
fun main(args: Array<String>) {
    val devDir = Files.createDirectories(Path.of(args.firstOrNull() ?: "build/dev").toAbsolutePath())
    val expired = EXPIRED_FLAG in args
    val createdAt = if (expired) Instant.now() - ServerTransfer.LIFETIME - Duration.ofMinutes(1) else Instant.now()
    val transfer = DevTransferLink.create(
        home = Files.createDirectories(devDir.resolve("home")),
        hostFingerprint = DevTransferLink.hostFingerprint(devDir.resolve("host_key")),
        port = DEV_PORT,
        createdAt = createdAt,
    )
    val link = transfer.urlString()
    val linkFile = devDir.resolve("transfer-link.txt")
    val qrFile = devDir.resolve("transfer-qr.png")
    linkFile.writeText(link + "\n")
    DevTransferLink.writeQrPng(link, qrFile)
    // Llevan la semilla de la clave (aunque sea de pruebas): solo legibles por el usuario.
    listOf(linkFile, qrFile).forEach { Files.setPosixFilePermissions(it, PosixFilePermissions.fromString("rw-------")) }
    val validity = if (expired) "YA CADUCADO (prueba del aviso)" else "caduca a los ${ServerTransfer.LIFETIME.toMinutes()} min"
    println(
        """
        |Enlace de prueba de «Enviar al iPhone» para el devServer ($validity).
        |  Servidor:   ${transfer.username}@${transfer.host}:${transfer.port}   (adb reverse tcp:$DEV_PORT tcp:$DEV_PORT)
        |  Huella:     ${transfer.hostKeyFingerprint}
        |  Clave:      ${transfer.keyComment}   (autorizada en ${EmbeddedSshServer.authorizedKeysFile(devDir.resolve("home"))})
        |  Enlace:     $linkFile
        |  QR (PNG):   $qrFile
        |  Deep link:  adb shell "am start -W -a android.intent.action.VIEW -d '${'$'}(cat $linkFile)' com.iaportafolio.argos"
        """.trimMargin(),
    )
}
