package com.iaportafolio.argos.ssh.testing

import com.iaportafolio.argos.core.keys.Ed25519Key
import com.iaportafolio.argos.core.keys.OpenSSHKeyWriter
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.CountDownLatch
import kotlin.io.path.exists
import kotlin.io.path.readText
import kotlin.io.path.writeText

/** Puerto fijo: el teléfono llega con `adb reverse tcp:2222 tcp:2222`. */
private const val DEV_PORT = 2222
private const val DEV_USER = "argos"
private const val DEV_PASSWORD = "argos-dev"
private const val CLIENT_KEY_NAME = "argos_dev_ed25519"
private const val CLIENT_KEY_COMMENT = "argos-dev-client"

/**
 * Servidor SSH de desarrollo para probar la app en un TELÉFONO FÍSICO (`./gradlew :ssh:devServer`).
 *
 * - 127.0.0.1:2222, usuario `argos` / contraseña `argos-dev`.
 * - Host key persistente en `<dir>/host_key`: la huella no cambia entre arranques (TOFU).
 * - Clave Ed25519 de cliente de prueba en `<dir>/argos_dev_ed25519` (OpenSSH, sin passphrase)
 *   y su `.pub`, autorizada en el servidor.
 * - `HOME` y tmux aislados en `<dir>/home` y `<dir>/tmux` (no toca tus sesiones reales); SFTP
 *   usa el mismo `HOME`.
 * - Proyecto de demo para el explorador de archivos en `~/proyectos/demo` ([ensureDemoProject]).
 *
 * El argumento es el directorio de trabajo (`android/ssh/build/dev`).
 */
fun main(args: Array<String>) {
    val devDir = Files.createDirectories(Path.of(args.firstOrNull() ?: "build/dev").toAbsolutePath())
    val clientKey = ensureClientKey(devDir)
    val server = EmbeddedSshServer.start(
        workDir = devDir,
        username = DEV_USER,
        password = DEV_PASSWORD,
        authorizedKeys = listOf(clientKey.publicLine),
        port = DEV_PORT,
    )
    val demo = ensureDemoProject(server.home)
    val stopped = CountDownLatch(1)
    Runtime.getRuntime().addShutdownHook(
        Thread {
            server.close()
            stopped.countDown()
        },
    )
    println(
        """
        |Servidor SSH de desarrollo de Argos en marcha.
        |  Dirección:   127.0.0.1:${server.port}   (teléfono: adb reverse tcp:$DEV_PORT tcp:$DEV_PORT)
        |  Usuario:     $DEV_USER
        |  Contraseña:  $DEV_PASSWORD
        |  Huella host: ${server.hostFingerprint}
        |  Clave host:  ${server.hostPublicKeyLine}
        |  Clave cliente (OpenSSH, sin passphrase): ${clientKey.privateFile}
        |  HOME remoto: ${server.home}   (SFTP sirve el mismo HOME)
        |  Proyecto demo: ${demoProjectSummary(demo)}   (en la app: ~/proyectos/demo)
        |  Prueba:      ssh -p $DEV_PORT -i ${clientKey.privateFile} $DEV_USER@127.0.0.1 tmux -V
        |Ctrl+C para detenerlo.
        |
        |${clientKey.privatePem}
        """.trimMargin(),
    )
    stopped.await()
}

private class DevClientKey(val privateFile: Path, val privatePem: String, val publicLine: String)

/** Genera (la primera vez) la clave de cliente de prueba con el mismo escritor que la app. */
private fun ensureClientKey(devDir: Path): DevClientKey {
    val privateFile = devDir.resolve(CLIENT_KEY_NAME)
    val publicFile = devDir.resolve("$CLIENT_KEY_NAME.pub")
    if (!privateFile.exists() || !publicFile.exists()) {
        val key = Ed25519Key.generate()
        privateFile.writeText(OpenSSHKeyWriter.privateKeyPem(key, CLIENT_KEY_COMMENT))
        publicFile.writeText(OpenSSHKeyWriter.authorizedKeyLine(key.publicKey, CLIENT_KEY_COMMENT) + "\n")
        // OpenSSH rechaza claves privadas legibles por otros.
        Files.setPosixFilePermissions(privateFile, PosixFilePermissions.fromString("rw-------"))
    }
    return DevClientKey(privateFile, privateFile.readText(), publicFile.readText().trim())
}
