package com.iaportafolio.argos.ssh.testing

import org.apache.sshd.common.config.keys.AuthorizedKeyEntry
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.config.keys.PublicKeyEntryResolver
import org.apache.sshd.common.digest.BuiltinDigests
import org.apache.sshd.common.file.FileSystemFactory
import org.apache.sshd.common.session.SessionContext
import org.apache.sshd.core.CoreModuleProperties
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
 * usuario, y el PATH nunca resuelve un `claude` instalado en la máquina (ver [environmentFor]).
 * [close] mata ese servidor tmux y los agentes que sigan corriendo en este `HOME`.
 *
 * Como OpenSSH (`MaxSessions`), admite [MAX_CHANNELS_PER_CONNECTION] canales por conexión.
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

    /** Conexiones SSH abiertas en este momento. */
    val activeConnections: Int get() = sshd.activeSessions.size

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

    /**
     * Procesos de esta máquina que son agentes o enganches de este `HOME`: el `claude` simulado,
     * su vigía y los `tail` del log. Líneas `pid args`. La línea de comandos lleva la ruta.
     */
    fun agentProcesses(): List<String> {
        val own = generateSequence(ProcessHandle.current()) { it.parent().orElse(null) }.map { it.pid() }.toSet()
        val process = ProcessBuilder("ps", "axww", "-o", "pid=,args=").redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        process.waitFor(LOCAL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        val roots = setOf(home.toString(), home.toRealPath().toString())
        val markers = roots.flatMap { listOf("$it/$AGENT_BINARY_PATH", "$it/$AGENTS_PATH/") }
        return output.lineSequence()
            .map { it.trim() }
            .filter { line -> markers.any { it in line } }
            .filter { it.substringBefore(' ').toLongOrNull() !in own }
            .toList()
    }

    /** Mata (SIGKILL) todo lo que devuelve [agentProcesses]. */
    fun killAgentProcesses() {
        val pids = agentProcesses().map { it.substringBefore(' ') }
        if (pids.isEmpty()) return
        ProcessBuilder(listOf("kill", "-9") + pids).redirectErrorStream(true).start().apply {
            inputStream.readBytes()
            waitFor(LOCAL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        }
    }

    override fun close() {
        killTmux()
        killAgentProcesses()
        sshd.stop(true)
        if (tmuxDir.startsWith(SHORT_TMP_ROOT)) tmuxDir.toFile().deleteRecursively()
    }

    companion object {
        private const val LOCAL_TIMEOUT_SECONDS = 30L

        /** `MaxSessions` por defecto de OpenSSH: lo que justifica las conexiones dedicadas. */
        const val MAX_CHANNELS_PER_CONNECTION = 10

        private const val AGENT_BINARY_PATH = FakeClaude.RELATIVE_PATH
        private const val AGENTS_PATH = ".config/argos/agents"

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
         * @param loginShell shell con el que `sshd` ejecuta los comandos (p. ej. `/bin/zsh`).
         */
        fun start(
            workDir: Path,
            username: String = "argos",
            password: String = "argos-test",
            authorizedKeys: List<String> = emptyList(),
            bindAddress: String = "127.0.0.1",
            port: Int = 0,
            hostKeyFile: Path = workDir.resolve("host_key"),
            loginShell: String = "/bin/sh",
        ): EmbeddedSshServer {
            val home = Files.createDirectories(workDir.resolve("home"))
            val tmuxDir = tmuxDirectory(workDir)
            val environment = environmentFor(username, home, tmuxDir, workDir)
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
                commandFactory = CommandFactory { _, command -> LocalShellCommand(command, environment, home, loginShell) }
                shellFactory = ShellFactory { LocalShellCommand(null, environment, home, loginShell) }
                fileSystemFactory = HomeFileSystemFactory(home)
                subsystemFactories = listOf(HomeSftpSubsystemFactory(home))
            }
            CoreModuleProperties.MAX_CONCURRENT_CHANNELS.set(sshd, MAX_CHANNELS_PER_CONNECTION)
            sshd.start()
            val hostPublicKey = hostKeys.loadKeys(null).first().public
            return EmbeddedSshServer(sshd, username, password, home, tmuxDir, hostPublicKey, environment)
        }

        private fun parsePublicKey(line: String): PublicKey =
            AuthorizedKeyEntry.parseAuthorizedKeyEntry(line).resolvePublicKey(null, PublicKeyEntryResolver.FAILING)

        /**
         * Entorno de los comandos: aislado del usuario real, con un PATH que encuentra tmux en
         * macOS (Homebrew) y Linux, y la locale UTF-8 para que tmux no degrade los caracteres.
         *
         * NUNCA debe resolver el `claude` real de la máquina: el `PATH` heredado suele traer
         * `~/.local/bin`. Se quitan los directorios con un `claude` y `~/.local/bin` del `HOME`
         * aislado (donde va [FakeClaude]) va el primero.
         */
        private fun environmentFor(username: String, home: Path, tmuxDir: Path, workDir: Path): Map<String, String> {
            val inherited = System.getenv("PATH").orEmpty().split(File.pathSeparator).filter { it.isNotBlank() }
            val (withClaude, clean) = (TOOL_DIRECTORIES + inherited).distinct().partition(::containsClaude)
            val tools = listOfNotNull(tmuxShim(workDir, withClaude, clean))
            val isolatedBin = home.resolve(AGENT_BINARY_PATH).parent.toString()
            return mapOf(
                "HOME" to home.toString(),
                "USER" to username,
                "LOGNAME" to username,
                "SHELL" to "/bin/sh",
                "PATH" to (listOf(isolatedBin) + tools + clean).joinToString(File.pathSeparator),
                "TMUX_TMPDIR" to tmuxDir.toString(),
                "LANG" to (System.getenv("LANG") ?: "C.UTF-8"),
            )
        }

        private fun containsClaude(directory: String): Boolean = Files.isExecutable(Path.of(directory, "claude"))

        /**
         * Si tmux solo está en un directorio que se quitó del PATH por tener un `claude`
         * (Homebrew con claude-code), se enlaza en un directorio propio. Devuelve ese directorio.
         */
        private fun tmuxShim(workDir: Path, excluded: List<String>, kept: List<String>): String? {
            if (kept.any { Files.isExecutable(Path.of(it, "tmux")) }) return null
            val tmux = excluded.map { Path.of(it, "tmux") }.firstOrNull(Files::isExecutable) ?: return null
            val shimDir = Files.createDirectories(workDir.resolve("tools"))
            Files.deleteIfExists(shimDir.resolve("tmux"))
            Files.createSymbolicLink(shimDir.resolve("tmux"), tmux)
            return shimDir.toString()
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
