package com.iaportafolio.argos.ssh.testing

import org.apache.sshd.common.config.keys.AuthorizedKeyEntry
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.config.keys.PublicKeyEntryResolver
import org.apache.sshd.common.digest.BuiltinDigests
import org.apache.sshd.common.file.FileSystemFactory
import org.apache.sshd.common.session.SessionContext
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.command.CommandFactory
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.server.shell.ShellFactory
import org.apache.sshd.server.channel.ChannelSession
import org.apache.sshd.server.command.Command
import org.apache.sshd.sftp.server.SftpSubsystem
import org.apache.sshd.sftp.server.SftpSubsystemConfigurator
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import java.io.File
import java.nio.file.FileSystem
import java.nio.file.FileSystems
import java.nio.file.LinkOption
import java.nio.file.Files
import java.nio.file.Path
import java.security.PublicKey
import java.util.AbstractMap
import java.util.concurrent.TimeUnit

/**
 * Servidor SSH embebido (Apache MINA SSHD) para los tests de integración y el `devServer`.
 *
 * Ejecuta los comandos en ESTA máquina con `/bin/sh -c`, pero aislados: `HOME` es [home] y
 * `TMUX_TMPDIR` es [tmuxDir], así que el servidor tmux de los tests es otro distinto del del
 * usuario. [close] mata ese servidor tmux.
 *
 * Autenticación: contraseña ([password]) y claves públicas autorizadas (líneas OpenSSH).
 * SFTP habilitado (subidas y explorador de archivos) sobre el sistema de archivos real, con
 * [home] como directorio inicial: las rutas relativas y `realpath(".")` dan el mismo `HOME`
 * aislado que ven los comandos. `realpath` resuelve symlinks como OpenSSH
 * ([HomeSftpSubsystemFactory]). Escucha solo en [bindAddress].
 */
class EmbeddedSshServer private constructor(
    private val sshd: SshServer,
    val username: String,
    val password: String,
    val home: Path,
    val tmuxDir: Path,
    /** Clave pública de host que presenta el servidor. */
    val hostPublicKey: PublicKey,
    private val environment: Map<String, String>,
) : AutoCloseable {

    val port: Int get() = sshd.port

    /** Línea OpenSSH de la clave de host (`ecdsa-sha2-nistp256 AAAA…`), para `ssh-keygen -l`. */
    val hostPublicKeyLine: String get() = PublicKeyEntry.toString(hostPublicKey)

    /** Huella de la clave de host según MINA (`SHA256:…`), referencia independiente de sshj. */
    val hostFingerprint: String get() = KeyUtils.getFingerPrint(BuiltinDigests.sha256, hostPublicKey)

    /** Ejecuta [command] localmente con el MISMO entorno que los comandos SSH (p. ej. para verificar). */
    fun runLocal(command: String): String {
        val process = ProcessBuilder("/bin/sh", "-c", command)
            .directory(home.toFile())
            .redirectErrorStream(true)
            .apply {
                environment().clear()
                environment().putAll(this@EmbeddedSshServer.environment)
            }
            .start()
        val output = process.inputStream.bufferedReader().readText()
        process.waitFor(LOCAL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        return output
    }

    /** Mata el servidor tmux aislado (si lo hay). */
    fun killTmux() {
        runLocal("tmux kill-server 2>/dev/null; true")
    }

    override fun close() {
        killTmux()
        sshd.stop(true)
        if (tmuxDir.startsWith(SHORT_TMP_ROOT)) tmuxDir.toFile().deleteRecursively()
    }

    companion object {
        private const val LOCAL_TIMEOUT_SECONDS = 30L

        /**
         * Los sockets Unix admiten ~104 bytes de ruta (macOS). tmux crea
         * `$TMUX_TMPDIR/tmux-<uid>/default`; si el directorio de trabajo es largo (el `TMPDIR` de
         * macOS lo es) se usa uno corto bajo `/tmp`.
         */
        private const val MAX_SOCKET_DIR_LENGTH = 80
        private val SHORT_TMP_ROOT: Path = Path.of("/tmp")

        private fun tmuxDirectory(workDir: Path): Path {
            val preferred = Files.createDirectories(workDir.resolve("tmux"))
            if (preferred.toRealPath().toString().length <= MAX_SOCKET_DIR_LENGTH) return preferred
            return Files.createTempDirectory(SHORT_TMP_ROOT, "argos-tmux-")
        }

        /** Directorios donde suele estar tmux (Homebrew en Apple Silicon/Intel, Linux). */
        private val TOOL_DIRECTORIES = listOf(
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        )

        /**
         * Arranca el servidor.
         *
         * @param workDir directorio de trabajo: dentro se crean `home/`, `tmux/` y (si no se
         *   indica [hostKeyFile]) la clave de host.
         * @param port 0 = puerto efímero.
         * @param hostKeyFile clave de host persistente (se genera la primera vez).
         * @param authorizedKeys líneas OpenSSH (`ssh-ed25519 AAAA… comentario`) aceptadas.
         */
        fun start(
            workDir: Path,
            username: String = "argos",
            password: String = "argos-test",
            authorizedKeys: List<String> = emptyList(),
            bindAddress: String = "127.0.0.1",
            port: Int = 0,
            hostKeyFile: Path = workDir.resolve("host_key"),
        ): EmbeddedSshServer {
            val home = Files.createDirectories(workDir.resolve("home"))
            val tmuxDir = tmuxDirectory(workDir)
            val environment = environmentFor(username, home, tmuxDir)
            val accepted = authorizedKeys.map(::parsePublicKey)
            val hostKeys = SimpleGeneratorHostKeyProvider(hostKeyFile)

            val sshd = SshServer.setUpDefaultServer().apply {
                host = bindAddress
                this.port = port
                keyPairProvider = hostKeys
                setPasswordAuthenticator { user, pass, _ -> user == username && pass == password }
                setPublickeyAuthenticator { user, key, _ ->
                    user == username && accepted.any { KeyUtils.compareKeys(it, key) }
                }
                keyboardInteractiveAuthenticator = null
                commandFactory = CommandFactory { _, command -> LocalShellCommand(command, environment, home) }
                shellFactory = ShellFactory { LocalShellCommand(null, environment, home) }
                fileSystemFactory = HomeFileSystemFactory(home)
                subsystemFactories = listOf(HomeSftpSubsystemFactory(home))
            }
            sshd.start()
            val hostPublicKey = hostKeys.loadKeys(null).first().public
            return EmbeddedSshServer(sshd, username, password, home, tmuxDir, hostPublicKey, environment)
        }

        private fun parsePublicKey(line: String): PublicKey =
            AuthorizedKeyEntry.parseAuthorizedKeyEntry(line).resolvePublicKey(null, PublicKeyEntryResolver.FAILING)

        /**
         * Entorno de los comandos: aislado del usuario real, con un PATH que encuentra tmux en
         * macOS (Homebrew) y Linux, y la locale UTF-8 para que tmux no degrade los caracteres.
         */
        private fun environmentFor(username: String, home: Path, tmuxDir: Path): Map<String, String> {
            val inherited = System.getenv("PATH").orEmpty().split(File.pathSeparator).filter { it.isNotBlank() }
            val path = (TOOL_DIRECTORIES + inherited).distinct().joinToString(File.pathSeparator)
            return mapOf(
                "HOME" to home.toString(),
                "USER" to username,
                "LOGNAME" to username,
                "SHELL" to "/bin/sh",
                "PATH" to path,
                "TMUX_TMPDIR" to tmuxDir.toString(),
                "LANG" to (System.getenv("LANG") ?: "C.UTF-8"),
            )
        }
    }
}

/**
 * Sistema de archivos REAL (rutas absolutas sin enjaular, como un sshd de verdad) con [home]
 * como directorio inicial de SFTP, igual que el `HOME` de los comandos.
 */
private class HomeFileSystemFactory(private val home: Path) : FileSystemFactory {
    override fun getUserHomeDir(session: SessionContext?): Path = home

    override fun createFileSystem(session: SessionContext?): FileSystem = FileSystems.getDefault()
}

/**
 * SFTP que se comporta como el `sftp-server` de OpenSSH en lo que importa al explorador:
 * - el directorio inicial es [home] (MINA usaría el directorio de trabajo de la JVM);
 * - `realpath` resuelve los symlinks (`realpath(3)`). MINA solo normaliza la ruta léxicamente;
 *   sin esto, la contención del explorador (basada en `realpath`, igual que en Apple) no se
 *   podría probar contra un symlink.
 */
private class HomeSftpSubsystemFactory(private val home: Path) : SftpSubsystemFactory() {
    override fun createSubsystem(channel: ChannelSession): Command = HomeSftpSubsystem(channel, this, home)
}

private class HomeSftpSubsystem(
    channel: ChannelSession,
    configurator: SftpSubsystemConfigurator,
    private val home: Path,
) : SftpSubsystem(channel, configurator) {

    override fun setFileSystem(fileSystem: FileSystem) {
        super.setFileSystem(fileSystem)
        defaultDir = home
    }

    override fun doRealPathV345(
        id: Int,
        path: String,
        p: Path,
        vararg options: LinkOption,
    ): AbstractMap.SimpleImmutableEntry<Path, Boolean> {
        val normalized = super.doRealPathV345(id, path, p, *options)
        val location = normalized.key
        val parent: Path? = location.parent
        val name: Path? = location.fileName
        // Como el `realpath` de OpenBSD que usa OpenSSH: el último componente puede no existir.
        val real = when {
            Files.exists(location) -> location.toRealPath()
            parent != null && name != null && Files.exists(parent) -> parent.toRealPath().resolve(name)
            else -> return normalized
        }
        return AbstractMap.SimpleImmutableEntry(real, normalized.value)
    }
}
