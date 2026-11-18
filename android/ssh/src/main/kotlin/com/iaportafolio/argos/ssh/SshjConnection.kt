package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.ConnectionHealth
import com.iaportafolio.argos.core.ConnectionPriority
import com.iaportafolio.argos.core.ConnectionProbeResult
import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.HostKeyStoreUnreadableException
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.ProbeOutcome
import com.iaportafolio.argos.core.SSHBackingOffException
import com.iaportafolio.argos.core.SSHFailureKind
import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import net.schmizz.keepalive.KeepAliveRunner
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.sftp.FileAttributes
import net.schmizz.sshj.sftp.OpenMode
import net.schmizz.sshj.sftp.SFTPClient
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
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration

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
 * - Todo lo bloqueante de sshj va en [Dispatchers.IO] y es interrumpible al cancelar, SALVO
 *   abrir un canal: interrumpirlo lo dejaría huérfano en el servidor ([openChannelDetached]).
 * - Los comandos cortos pasan por un tope de canales con reintento ([withShortChannel]) y tienen
 *   plazo ([CommandTimeouts]); un comando vencido sigue ocupando su turno hasta que su canal se
 *   cierra de verdad y, con varios así, la conexión se recicla.
 * - [health] decide si se puede intentar conectar (ver `ConnectionHealth`): credenciales
 *   rechazadas o host key cambiada no se reintentan en segundo plano, y tras un fallo de red el
 *   fondo espera cada vez más ([ConnectionPriority]).
 */
internal class SshjConnection(
    private val server: Server,
    private val credentials: SSHCredentials,
    private val trust: HostKeyTrustStore,
    private val settings: SshjConnector.Settings,
) {
    private val mutex = Mutex()
    private var client: SSHClient? = null

    /** Tope de canales cortos simultáneos en la conexión compartida. */
    private val gate = ChannelGate()

    /**
     * Trabajo desacoplado de quien llama: aperturas de canal abandonadas (se cierran al terminar
     * de abrirse), cierres que pueden esperar al servidor y sondas. Vive lo que el servicio.
     */
    private val channelScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Conexiones de canales largos abiertas ahora mismo (ver [withDedicatedClient]). */
    private val dedicated: MutableSet<SSHClient> = ConcurrentHashMap.newKeySet()

    /** Salud de los intentos de conexión (compartida y dedicadas). */
    @Volatile
    private var health = ConnectionHealth()
    private val healthLock = Any()

    /** Comandos vencidos cuyo canal aún no se ha cerrado (en la conexión compartida actual). */
    private val abandoned = AtomicInteger(0)

    /** Salud actual (para los tests y la interfaz). */
    val connectionHealth: ConnectionHealth get() = health

    /** `host:puerto` del servidor, para los mensajes de error. */
    val endpoint: String get() = server.endpoint

    /** Espera máxima al cierre de un canal tras leer su salida. */
    val channelCloseTimeoutSeconds: Long get() = settings.channelCloseTimeoutSeconds

    /** Conexión viva (la abre si hace falta). */
    suspend fun connectedClient(): SSHClient = mutex.withLock {
        client?.takeIf { it.isConnected && it.isAuthenticated } ?: run {
            client?.let { stale -> withContext(Dispatchers.IO) { closeQuietly(stale) } }
            client = null
            val opened = attemptConnection { open() }
            // Conexión nueva: tope de partida y ningún canal abandonado.
            gate.resetLimit()
            abandoned.set(0)
            opened.also { client = it }
        }
    }

    /**
     * Intenta conectar si [health] lo admite para la prioridad actual y registra el resultado. La
     * cancelación no cuenta como fallo.
     *
     * @throws SSHBackingOffException el fondo debe esperar todavía (sin tocar la red).
     */
    private suspend fun <T> attemptConnection(open: suspend () -> T): T {
        val priority = ConnectionPriority.current()
        when (val admission = health.admission(priority, nowMillis())) {
            ConnectionHealth.Admission.Allowed -> Unit
            is ConnectionHealth.Admission.Blocked ->
                throw SSHBackingOffException(ConnectionHealth.MAX_BACKOFF_MILLIS, health.lastFailureMessage)
            is ConnectionHealth.Admission.Deferred ->
                throw SSHBackingOffException(admission.remainingMillis, health.lastFailureMessage)
        }
        return try {
            open().also { synchronized(healthLock) { health = health.recordingSuccess() } }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            val kind = failureKind(error)
            synchronized(healthLock) { health = health.recordingFailure(kind, error.userMessage, nowMillis()) }
            throw error
        }
    }

    /** Acción explícita del usuario: olvida el bloqueo y la espera entre reintentos. */
    fun resetConnectionHealth() {
        synchronized(healthLock) { health = ConnectionHealth() }
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
            attemptConnection { runInterruptible(Dispatchers.IO) { connect(pending) } }
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
     *
     * Respeta el tope de canales ([ChannelGate]) y reintenta si el servidor rechaza el canal. Si
     * el comando no termina en [timeout], se cancela, se libera el canal y lanza
     * [SshCommandTimeoutException]. Los fallos de transporte llegan traducidos
     * ([translateTransportError]).
     */
    suspend fun capture(command: String, timeout: Duration = CommandTimeouts.SHORT): CommandResult =
        captureInTurn(command, timeout) { connectedClient() }

    /**
     * Como [capture] pero SOLO si la conexión compartida ya está viva (no reconecta: p. ej. al
     * desconectar). `null` si no había conexión.
     */
    suspend fun captureIfConnected(command: String, timeout: Duration = CommandTimeouts.SHORT): CommandResult? {
        val ssh = liveClient() ?: return null
        return captureInTurn(command, timeout) { ssh }
    }

    /**
     * Un comando con plazo dentro de un turno de canal. Si el plazo vence, quien llama recibe
     * [SshCommandTimeoutException] enseguida, pero el turno NO se libera hasta que el canal se
     * cierra de verdad (lo suelta la propia tarea, desacoplada): si no, los canales colgados se
     * acumularían en el servidor por encima de `MaxSessions`. Pasados
     * [CommandTimeouts.ABANDONED_CHANNEL_LIMIT] así, se recicla la conexión compartida. Si el
     * servidor rechaza el canal, el tope baja y se reintenta (el comando nunca llegó a correr).
     */
    private suspend fun captureInTurn(command: String, timeout: Duration, client: suspend () -> SSHClient): CommandResult {
        val priority = ConnectionPriority.current()
        var attempt = 1
        while (true) {
            gate.acquire(priority)
            val ssh = try {
                client()
            } catch (error: Throwable) {
                gate.release(priority)
                throw error
            }
            try {
                return runHoldingTurn(ssh, command, timeout, priority)
            } catch (error: IOException) {
                currentCoroutineContext().ensureActive()
                if (!ChannelRetry.isRejection(error)) throw translateTransportError(error, endpoint, ssh.isConnected)
                if (attempt >= ChannelRetry.MAX_ATTEMPTS) throw SshChannelRejectedException(endpoint, error)
                delay(ChannelRetry.delay(attempt))
                attempt += 1
            }
        }
    }

    /** Ver [captureInTurn]: el turno (ya cogido) lo devuelve la tarea al cerrar el canal. */
    private suspend fun runHoldingTurn(ssh: SSHClient, command: String, timeout: Duration, priority: ConnectionPriority): CommandResult {
        val abandonedHere = java.util.concurrent.atomic.AtomicBoolean(false)
        val operation = channelScope.async {
            var rejected = false
            try {
                captureClosing(ssh, command)
            } catch (error: IOException) {
                rejected = ChannelRetry.isRejection(error)
                throw error
            } finally {
                if (abandonedHere.get()) abandoned.decrementAndGet()
                if (rejected) gate.lowerLimitAfterRejection()
                gate.release(priority)
            }
        }
        val result = try {
            withTimeoutOrNull(timeout) { operation.await() }
        } catch (cancelled: CancellationException) {
            operation.cancel()
            throw cancelled
        }
        if (result != null) return result
        // Vencido: se deja de esperar y se cancela (cerrar el canal puede tardar: lo hace la tarea).
        abandonedHere.set(true)
        val count = abandoned.incrementAndGet()
        operation.cancel()
        if (count >= CommandTimeouts.ABANDONED_CHANNEL_LIMIT) {
            abandoned.set(0)
            recycle(ssh)
        }
        throw SshCommandTimeoutException(endpoint, timeout.inWholeSeconds)
    }

    /**
     * Ejecuta [body], que abre UN canal corto en la conexión de [client], respetando el tope de
     * la conexión y reintentando con espera creciente si el servidor rechaza el canal (el
     * rechazo llega antes de ejecutar nada: repetir es seguro). Si el rechazo persiste, recicla
     * la conexión (la siguiente operación abre otra) y lanza [SshChannelRejectedException].
     */
    suspend fun <T> withShortChannel(client: suspend () -> SSHClient, body: suspend (SSHClient) -> T): T {
        val priority = ConnectionPriority.current()
        var attempt = 1
        while (true) {
            gate.acquire(priority)
            var ssh: SSHClient? = null
            try {
                // Dentro del turno: quien esperaba en cola usa la conexión vigente al entrar.
                val current = client().also { ssh = it }
                return body(current)
            } catch (error: IOException) {
                currentCoroutineContext().ensureActive()
                val open = ssh ?: throw error
                if (!ChannelRetry.isRejection(error)) throw translateTransportError(error, endpoint, open.isConnected)
                // Un rechazo prueba que el servidor está vivo: no se recicla, se baja el tope.
                gate.lowerLimitAfterRejection()
                if (attempt >= ChannelRetry.MAX_ATTEMPTS) throw SshChannelRejectedException(endpoint, error)
            } finally {
                gate.release(priority)
            }
            delay(ChannelRetry.delay(attempt))
            attempt += 1
        }
    }

    /** Abre una sesión (canal) sin dejarla huérfana si se cancela a mitad (ver [openChannelDetached]). */
    suspend fun openSession(ssh: SSHClient): Session = channelScope.openChannelDetached { ssh.startSession() }

    /** Abre un subsistema SFTP sin dejarlo huérfano si se cancela a mitad. Usar dentro de [withShortChannel]. */
    suspend fun openSftp(ssh: SSHClient): SFTPClient = channelScope.openChannelDetached { ssh.newSFTPClient() }

    /**
     * Abre un canal, ejecuta [command] y CIERRA el canal antes de volver, también si se cancela
     * (el cierre puede esperar al servidor: lo usa una tarea desacoplada, ver [runHoldingTurn]).
     */
    private suspend fun captureClosing(ssh: SSHClient, command: String): CommandResult {
        val session = openSession(ssh)
        try {
            return runCommand(session, command)
        } finally {
            withContext(NonCancellable + Dispatchers.IO) { closeChannelQuietly(session) }
        }
    }

    private suspend fun captureOn(ssh: SSHClient, command: String, timeout: Duration): CommandResult {
        val session = openSession(ssh)
        var finished = false
        try {
            val result = withTimeoutOrNull(timeout) { runCommand(session, command) }
                ?: throw SshCommandTimeoutException(endpoint, timeout.inWholeSeconds)
            finished = true
            return result
        } finally {
            if (finished) {
                withContext(NonCancellable + Dispatchers.IO) { closeChannelQuietly(session) }
            } else {
                // Cancelado, caducado o con error: cerrar puede esperar al servidor (conexión
                // colgada), así que no se retiene al llamador.
                channelScope.launch { closeChannelQuietly(session) }
            }
        }
    }

    private suspend fun runCommand(session: Session, command: String): CommandResult = coroutineScope {
        val running = interruptible { session.exec(command) }
        running.outputStream.close()
        val stderr = async { interruptible { running.errorStream.readBytes() } }
        val stdout = interruptible { running.inputStream.readBytes() }
        val errBytes = stderr.await()
        interruptible { running.join(settings.channelCloseTimeoutSeconds, TimeUnit.SECONDS) }
        CommandResult(
            stdout = stdout.toString(Charsets.UTF_8),
            stderr = errBytes.toString(Charsets.UTF_8),
            exitCode = running.exitStatus ?: SIGNAL_EXIT_CODE,
        )
    }

    /**
     * Llamada bloqueante de sshj en [Dispatchers.IO], interrumpible al cancelar. Si falla por la
     * cancelación (sshj convierte la interrupción en un error de E/S) se relanza la cancelación.
     */
    private suspend fun <T> interruptible(block: () -> T): T = try {
        runInterruptible(Dispatchers.IO, block)
    } catch (error: IOException) {
        currentCoroutineContext().ensureActive()
        throw error
    }

    // MARK: Salud de la conexión

    /**
     * Comprueba con un comando trivial y un plazo corto que la conexión compartida responde. Una
     * conexión medio abierta (cambio de red, NAT que la olvidó) no falla: se queda esperando
     * hasta el timeout de TCP o el keep-alive (minutos). No espera a que la comprobación acabe
     * si vence el plazo (como `Deadline` de Apple).
     */
    suspend fun probe(timeout: Duration = CommandTimeouts.PROBE): ConnectionProbeResult {
        val ssh = mutex.withLock { client } ?: return ConnectionProbeResult.NOT_CONNECTED
        if (!ssh.isConnected || !ssh.isAuthenticated) {
            recycle(ssh)
            return ConnectionProbeResult.RECYCLED
        }
        // Fuera del cupo de canales (como el latido de Apple): con la cola llena, esperar turno
        // no es «conexión muerta».
        val check = channelScope.async { probeOutcome { captureOn(ssh, PROBE_COMMAND, timeout) } }
        val outcome = try {
            withTimeoutOrNull(timeout) { check.await() } ?: ProbeOutcome.UNRESPONSIVE
        } catch (cancelled: CancellationException) {
            check.cancel()
            throw cancelled
        }
        // Un canal rechazado también es respuesta: el servidor está vivo, solo sin canales libres.
        if (outcome == ProbeOutcome.ALIVE || outcome == ProbeOutcome.REJECTED) return ConnectionProbeResult.ALIVE
        check.cancel()
        recycle(ssh)
        return ConnectionProbeResult.RECYCLED
    }

    /** Clasifica el resultado de una sonda (port de `ProbeOutcome.from(error:)`). */
    private suspend fun probeOutcome(probe: suspend () -> CommandResult): ProbeOutcome = try {
        probe()
        ProbeOutcome.ALIVE
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: IOException) {
        when {
            ChannelRetry.isRejection(error) -> ProbeOutcome.REJECTED
            translateTransportError(error, endpoint, false) is SshConnectionException.ConnectionClosed -> ProbeOutcome.BROKEN
            else -> ProbeOutcome.UNRESPONSIVE
        }
    } catch (_: SshCommandTimeoutException) {
        ProbeOutcome.UNRESPONSIVE
    }

    /** Suelta [stale] si sigue siendo la conexión compartida y la cierra sin esperar. */
    private suspend fun recycle(stale: SSHClient) {
        val dropped = mutex.withLock { (client === stale).also { if (it) client = null } }
        if (dropped) channelScope.launch { closeQuietly(stale) }
    }

    private suspend fun liveClient(): SSHClient? = mutex.withLock { client?.takeIf { it.isConnected && it.isAuthenticated } }

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
        try {
            withShortChannel({ connectedClient() }) { ssh ->
                val sftp = openSftp(ssh)
                try {
                    interruptible {
                        sftp.open(remotePath, EnumSet.of(OpenMode.WRITE, OpenMode.CREAT, mode), PRIVATE_FILE).use { file ->
                            file.RemoteFileOutputStream(0).use { it.write(data) }
                        }
                    }
                } finally {
                    withContext(NonCancellable + Dispatchers.IO) { closeChannelQuietly(sftp) }
                }
            }
        } catch (error: IOException) {
            throw SSHServiceError.UploadFailed(error.userMessage)
        } catch (error: SshConnectionException) {
            throw SSHServiceError.UploadFailed(error.userMessage)
        } catch (error: SshChannelRejectedException) {
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
        verifier.rejection?.let { return it }
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

    private fun nowMillis(): Long = System.nanoTime() / NANOS_PER_MILLI

    /** Qué clase de fallo es abrir una conexión (port de `SSHFailureKind.classify`). */
    private fun failureKind(error: Exception): SSHFailureKind = when (error) {
        is HostKeyMismatchException, is HostKeyStoreUnreadableException -> SSHFailureKind.HOST_KEY
        is SshConnectionException.AuthenticationFailed, is SSHServiceError.KeyParseFailed, is SSHServiceError.KeyUnreadable ->
            SSHFailureKind.AUTHENTICATION
        else -> SSHFailureKind.NETWORK
    }

    private companion object {
        const val NANOS_PER_MILLI = 1_000_000L

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

/** Comando de la sonda de salud: trivial, sin salida. */
private const val PROBE_COMMAND = "true"
