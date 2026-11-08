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
import net.schmizz.sshj.sftp.FileAttributes
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Resultado de un comando remoto: un código distinto de 0 NO es una excepción. */
internal data class CommandResult(val stdout: String, val stderr: String, val exitCode: Int)

/**
 * Conexión SSH perezosa y reutilizada de un servidor (port de `connectedClient()`, `capture`
 * y `upload` de `SSHService.swift`).
 *
 * - Se abre en la primera operación y se reutiliza; si se cae, la siguiente la reabre.
 * - [mutex] serializa SOLO la apertura/cierre (equivale al aislamiento del `actor`): se suelta
 *   al obtener el cliente. Los comandos y los terminales en vivo (canales largos, ver
 *   [SshjTerminal]) corren en paralelo como canales independientes de la misma conexión.
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

    /** Conexiones de canales largos abiertas ahora mismo (ver [withDedicatedClient]). */
    private val dedicated: MutableSet<SSHClient> = ConcurrentHashMap.newKeySet()

    /** `host:puerto` del servidor, para los mensajes de error. */
    val endpoint: String get() = server.endpoint

    /** Espera máxima al cierre de un canal tras leer su salida. */
    val channelCloseTimeoutSeconds: Long get() = settings.channelCloseTimeoutSeconds

    /** Conexión viva (la abre si hace falta). */
    suspend fun connectedClient(): SSHClient = mutex.withLock {
        client?.takeIf { it.isConnected && it.isAuthenticated } ?: run {
            client?.let { stale -> withContext(Dispatchers.IO) { closeQuietly(stale) } }
            client = null
            open().also { client = it }
        }
    }

    /**
     * Ejecuta [block] sobre una conexión PROPIA (mismas credenciales y TOFU) que se cierra siempre
     * al terminar, también si se cancela (port de `withDedicatedClient` de `SSHService.swift`).
     * OpenSSH limita los canales por conexión (`MaxSessions`, 10 por defecto): los canales de
     * larga duración de los agentes no deben agotar los de la conexión compartida.
     *
     * El cliente se crea ANTES de conectar para poder cerrarlo pase lo que pase: si la cancelación
     * llegara justo al terminar de conectar, un cliente devuelto por `withContext` se perdería.
     */
    suspend fun <T> withDedicatedClient(block: suspend (SSHClient) -> T): T {
        val pending = withContext(Dispatchers.IO) { newClient() }
        try {
            runInterruptible(Dispatchers.IO) { connect(pending) }
            dedicated += pending.ssh
            return block(pending.ssh)
        } finally {
            dedicated -= pending.ssh
            withContext(NonCancellable + Dispatchers.IO) { closeQuietly(pending.ssh) }
        }
    }

    /** Cierra la conexión y las dedicadas abiertas. Idempotente y no cancelable a medias. */
    suspend fun disconnect() {
        withContext(NonCancellable) {
            mutex.withLock {
                val current = client
                client = null
                current?.let { withContext(Dispatchers.IO) { closeQuietly(it) } }
            }
            val open = dedicated.drainConcurrently()
            if (open.isNotEmpty()) withContext(Dispatchers.IO) { open.forEach(::closeQuietly) }
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
     * Escribe [data] en [remotePath] por SFTP: el contenido nunca viaja por la línea de
     * comandos (no queda expuesto en `ps`). Se crea con permisos 0600. Con [exclusive] (por
     * defecto, para rutas en `/tmp`, que es compartido) se abre con `O_EXCL`: falla si ya
     * existe, incluido un symlink plantado por otro usuario. Solo se pasa `false` para un
     * temporal ya preparado en un directorio privado de `$HOME` (umask 077), que hay que
     * truncar. Lanza [SSHServiceError.UploadFailed].
     */
    suspend fun upload(data: ByteArray, remotePath: String, exclusive: Boolean = true): String {
        val mode = if (exclusive) OpenMode.EXCL else OpenMode.TRUNC
        val ssh = connectedClient()
        try {
            runInterruptible(Dispatchers.IO) {
                ssh.newSFTPClient().use { sftp ->
                    sftp.open(remotePath, EnumSet.of(OpenMode.WRITE, OpenMode.CREAT, mode), PRIVATE_FILE).use { file ->
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

    private class PendingClient(val ssh: SSHClient, val verifier: TofuHostKeyVerifier)

    private suspend fun open(): SSHClient = runInterruptible(Dispatchers.IO) {
        val pending = newClient()
        connect(pending)
        pending.ssh
    }

    private fun newClient(): PendingClient {
        val verifier = TofuHostKeyVerifier(server.endpoint, trust)
        val ssh = SSHClient(SshjConnector.config()).apply {
            addHostKeyVerifier(verifier)
            connectTimeout = settings.connectTimeoutMillis
            // Antes de connect(): sshj arranca el hilo de keep-alive al conectar si el intervalo > 0.
            connection.keepAlive.keepAliveInterval = settings.keepAliveIntervalSeconds
            (connection.keepAlive as? KeepAliveRunner)?.maxAliveCount = settings.keepAliveMaxMissed
        }
        return PendingClient(ssh, verifier)
    }

    /** Conecta y autentica; si falla, cierra el cliente y lanza el error traducido. */
    private fun connect(pending: PendingClient) {
        val ssh = pending.ssh
        try {
            ssh.connect(server.host, server.port)
            authenticate(ssh)
        } catch (error: IOException) {
            closeQuietly(ssh)
            throw translate(error, pending.verifier)
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

        /** Permisos 0600: solo el usuario remoto puede leer o escribir la subida. */
        val PRIVATE_FILE: FileAttributes = FileAttributes.Builder().withPermissions(0b110_000_000).build()
    }
}

/**
 * Saca y devuelve lo que haya en un conjunto concurrente. `toList()` de Kotlin NO vale aquí: con
 * un elemento consulta `size` y luego `iterator().next()`, que lanza si otro hilo lo quitó entre
 * medias. `toArray` toma una foto consistente, y quitar uno a uno no pierde lo añadido después.
 */
internal fun <T> MutableSet<T>.drainConcurrently(): List<T> {
    val snapshot = ArrayList(this)
    return snapshot.filter { remove(it) }
}
