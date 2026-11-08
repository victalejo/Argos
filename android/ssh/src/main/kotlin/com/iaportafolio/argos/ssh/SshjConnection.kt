package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.userMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import net.schmizz.keepalive.KeepAliveRunner
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.sftp.OpenMode
import net.schmizz.sshj.transport.TransportException
import net.schmizz.sshj.userauth.UserAuthException
import net.schmizz.sshj.userauth.keyprovider.KeyProvider
import net.schmizz.sshj.userauth.password.PasswordUtils
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.EnumSet
import java.util.concurrent.TimeUnit

/** Resultado de un comando remoto: un código distinto de 0 NO es una excepción. */
internal data class CommandResult(val stdout: String, val stderr: String, val exitCode: Int)

/**
 * Conexión SSH perezosa y reutilizada de un servidor (port de `connectedClient()`, `capture`
 * y `upload` de `SSHService.swift`).
 *
 * - Se abre en la primera operación y se reutiliza; si se cae, la siguiente la reabre.
 * - [mutex] serializa la apertura/cierre (equivale al aislamiento del `actor`); los comandos
 *   corren en paralelo como canales independientes de la misma conexión.
 * - Todo lo bloqueante de sshj va en [Dispatchers.IO] y es interrumpible al cancelar.
 */
internal class SshjConnection(
    private val server: Server,
    private val credentials: SSHCredentials,
    private val trust: HostKeyTrustStore,
    private val settings: SshjConnector.Settings,
) {
    private val mutex = Mutex()
    private var client: SSHClient? = null

    /** Conexión viva (la abre si hace falta). */
    suspend fun connectedClient(): SSHClient = mutex.withLock {
        client?.takeIf { it.isConnected && it.isAuthenticated } ?: run {
            client?.let { stale -> withContext(Dispatchers.IO) { closeQuietly(stale) } }
            client = null
            open().also { client = it }
        }
    }

    /** Cierra la conexión si está abierta. Idempotente y no cancelable a medias. */
    suspend fun disconnect() {
        withContext(NonCancellable) {
            mutex.withLock {
                val current = client
                client = null
                current?.let { withContext(Dispatchers.IO) { closeQuietly(it) } }
            }
        }
    }

    /**
     * Ejecuta [command] capturando stdout, stderr y el código de salida. Un código distinto de
     * cero NO lanza (lo decide la capa superior, p. ej. tmux sin servidor → lista vacía).
     * Se cierra stdin (EOF) para que ningún comando se quede esperando entrada.
     */
    suspend fun capture(command: String): CommandResult {
        val ssh = connectedClient()
        return withContext(Dispatchers.IO) {
            val session = runInterruptible { ssh.startSession() }
            try {
                runCommand(session, command)
            } finally {
                withContext(NonCancellable) { closeSessionQuietly(session) }
            }
        }
    }

    private suspend fun runCommand(session: Session, command: String): CommandResult = coroutineScope {
        val running = runInterruptible { session.exec(command) }
        running.outputStream.close()
        val stderr = async(Dispatchers.IO) { runInterruptible { running.errorStream.readBytes() } }
        val stdout = runInterruptible { running.inputStream.readBytes() }
        val errBytes = stderr.await()
        runInterruptible { running.join(settings.channelCloseTimeoutSeconds, TimeUnit.SECONDS) }
        CommandResult(
            stdout = stdout.toString(Charsets.UTF_8),
            stderr = errBytes.toString(Charsets.UTF_8),
            exitCode = running.exitStatus ?: SIGNAL_EXIT_CODE,
        )
    }

    /**
     * Escribe [data] en [remotePath] por SFTP (crea/trunca): el contenido nunca viaja por la
     * línea de comandos (no queda expuesto en `ps`). Lanza [SSHServiceError.UploadFailed].
     */
    suspend fun upload(data: ByteArray, remotePath: String): String {
        val ssh = connectedClient()
        try {
            runInterruptible(Dispatchers.IO) {
                ssh.newSFTPClient().use { sftp ->
                    sftp.open(remotePath, EnumSet.of(OpenMode.WRITE, OpenMode.CREAT, OpenMode.TRUNC)).use { file ->
                        file.RemoteFileOutputStream(0).use { it.write(data) }
                    }
                }
            }
        } catch (error: IOException) {
            throw SSHServiceError.UploadFailed(error.userMessage)
        }
        return remotePath
    }

    // MARK: Apertura

    private suspend fun open(): SSHClient = runInterruptible(Dispatchers.IO) {
        val verifier = TofuHostKeyVerifier(server.endpoint, trust)
        val ssh = SSHClient(SshjConnector.config()).apply {
            addHostKeyVerifier(verifier)
            connectTimeout = settings.connectTimeoutMillis
            // Antes de connect(): sshj arranca el hilo de keep-alive al conectar si el intervalo > 0.
            connection.keepAlive.keepAliveInterval = settings.keepAliveIntervalSeconds
            (connection.keepAlive as? KeepAliveRunner)?.maxAliveCount = settings.keepAliveMaxMissed
        }
        try {
            ssh.connect(server.host, server.port)
            authenticate(ssh)
            ssh
        } catch (error: IOException) {
            closeQuietly(ssh)
            throw translate(error, verifier)
        } catch (error: SSHServiceError) {
            closeQuietly(ssh)
            throw error
        }
    }

    private fun authenticate(ssh: SSHClient) {
        when (val secret = credentials) {
            is SSHCredentials.Password -> ssh.authPassword(server.username, secret.password)
            is SSHCredentials.PrivateKey -> ssh.authPublickey(server.username, loadKey(ssh, secret))
        }
    }

    /**
     * Carga la clave OpenSSH desde su CONTENIDO (nunca se escribe en disco) y la descifra YA,
     * para distinguir «clave/passphrase inválida» de «el servidor no acepta la clave».
     */
    private fun loadKey(ssh: SSHClient, secret: SSHCredentials.PrivateKey): KeyProvider {
        val finder = secret.passphrase?.let { PasswordUtils.createOneOff(it.toCharArray()) }
        return try {
            ssh.loadKeys(secret.openSSHPem, null, finder).also { provider ->
                provider.private
                provider.public
            }
        } catch (error: IOException) {
            throw SSHServiceError.KeyParseFailed(error)
        } catch (error: IllegalArgumentException) {
            throw SSHServiceError.KeyParseFailed(error)
        }
    }

    private fun translate(error: IOException, verifier: TofuHostKeyVerifier): Exception {
        verifier.mismatch?.let { return it }
        val endpoint = server.endpoint
        return when (error) {
            is UserAuthException -> SshConnectionException.AuthenticationFailed(server.username, error)
            is SocketTimeoutException -> SshConnectionException.Timeout(endpoint, error)
            is UnknownHostException, is ConnectException, is NoRouteToHostException ->
                SshConnectionException.Unreachable(endpoint, error)
            is TransportException -> (error.cause as? SocketTimeoutException)
                ?.let { SshConnectionException.Timeout(endpoint, error) }
                ?: SshConnectionException.ProtocolFailed(endpoint, error)
            else -> SshConnectionException.ProtocolFailed(endpoint, error)
        }
    }

    private fun closeQuietly(ssh: SSHClient) {
        try {
            ssh.disconnect()
        } catch (_: IOException) {
            // Cerrar una conexión ya caída puede fallar: no hay nada más que hacer.
        }
    }

    private fun closeSessionQuietly(session: Session) {
        try {
            session.close()
        } catch (_: IOException) {
            // El canal pudo cerrarse ya por el servidor (o por la conexión caída).
        }
    }

    private companion object {
        /** El proceso terminó por una señal (sin `exit-status`). */
        const val SIGNAL_EXIT_CODE = -1
    }
}
