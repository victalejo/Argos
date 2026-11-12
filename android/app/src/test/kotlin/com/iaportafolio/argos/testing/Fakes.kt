package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.core.tmux.TmuxPaneDirection
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.core.tmux.WindowColor
import com.iaportafolio.argos.data.DocumentReader
import com.iaportafolio.argos.data.SecretCipher
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

fun server(
    id: String = "S1",
    name: String = "dev",
    host: String = "dev.example.com",
    port: Int = 22,
    authMethod: com.iaportafolio.argos.core.AuthMethod = com.iaportafolio.argos.core.AuthMethod.PASSWORD,
    requiresPassphrase: Boolean = false,
) = Server(id = id, name = name, host = host, port = port, username = "victor", authMethod = authMethod, requiresPassphrase = requiresPassphrase)

fun session(name: String, windows: Int = 1, attached: Boolean = false) =
    TmuxSession(name, windows, attached, Instant.ofEpochSecond(1_700_000_000))

class InMemoryServerRepository(initial: List<Server> = emptyList()) : ServerRepository {
    private val state = MutableStateFlow(initial)
    override val servers: StateFlow<List<Server>> = state
    var failWrites: Exception? = null

    override suspend fun upsert(server: Server) {
        failWrites?.let { throw it }
        val current = state.value
        state.value = if (current.any { it.id == server.id }) current.map { if (it.id == server.id) server else it } else current + server
    }

    override suspend fun delete(id: String) {
        failWrites?.let { throw it }
        state.value = state.value.filterNot { it.id == id }
    }
}

class InMemorySecretStore : SecretStore {
    val values = mutableMapOf<Pair<String, SecretKind>, String>()
    val deletedAll = mutableListOf<String>()

    override fun read(serverId: String, kind: SecretKind): String? = values[serverId to kind]
    override fun contains(serverId: String, kind: SecretKind): Boolean = (serverId to kind) in values
    override fun write(serverId: String, kind: SecretKind, value: String) {
        values[serverId to kind] = value
    }
    override fun delete(serverId: String, kind: SecretKind) {
        values.remove(serverId to kind)
    }
    override fun deleteAll(serverId: String) {
        deletedAll += serverId
        values.keys.removeAll { it.first == serverId }
    }
}

class InMemoryTrustStore(initial: Map<String, String> = emptyMap()) : HostKeyTrustStore {
    val known = initial.toMutableMap()
    override fun trustedFingerprint(endpoint: String): String? = known[endpoint]
    override fun trust(endpoint: String, fingerprint: String) {
        known[endpoint] = fingerprint
    }
    override fun forget(endpoint: String) {
        known.remove(endpoint)
    }
}

/** AES-GCM con claves en memoria: misma semántica que el Keystore (clave por id, AAD, borrado). */
class SoftwareCipher : SecretCipher {
    val keys = mutableMapOf<String, SecretKey>()
    val deletedKeys = mutableListOf<String>()
    private val random = SecureRandom()

    override fun encrypt(keyId: String, plaintext: ByteArray, aad: ByteArray): ByteArray {
        val key = keys.getOrPut(keyId) { KeyGenerator.getInstance("AES").apply { init(256) }.generateKey() }
        val iv = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        return iv + cipher.doFinal(plaintext)
    }

    override fun decrypt(keyId: String, blob: ByteArray, aad: ByteArray): ByteArray {
        val key = keys[keyId] ?: throw GeneralSecurityException("sin clave")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, blob, 0, 12))
        cipher.updateAAD(aad)
        return cipher.doFinal(blob, 12, blob.size - 12)
    }

    override fun deleteKey(keyId: String) {
        deletedKeys += keyId
        keys.remove(keyId)
    }
}

class FakeDocumentReader(var bytes: ByteArray = ByteArray(0), var error: Exception? = null) : DocumentReader {
    val requested = mutableListOf<String>()
    override suspend fun read(uri: String, maxBytes: Int): ByteArray {
        requested += uri
        error?.let { throw it }
        return bytes
    }
}

class FakeServiceProvider(var service: FakeSSHService = FakeSSHService()) : ServiceProvider {
    var error: Exception? = null
    val requested = mutableListOf<Server>()
    val invalidated = mutableListOf<String>()

    override suspend fun service(server: Server): SSHServicing {
        requested += server
        error?.let { throw it }
        return service
    }

    override suspend fun invalidate(serverId: String) {
        invalidated += serverId
    }
}

/** Doble de [SSHServicing] para tmux y proyectos; el resto no se usa todavía. */
class FakeSSHService : SSHServicing {
    var tmuxInstalled = true
    var canSudo = false
    var configExists = true
    var sessions: List<TmuxSession> = emptyList()
    var listError: Exception? = null
    var tmuxCheckError: Exception? = null
    var managementError: Exception? = null

    /** Si no es null, `listSessions` espera a que se complete (para observar estados intermedios). */
    var listGate: CompletableDeferred<Unit>? = null

    val calls = mutableListOf<String>()
    var disconnects = 0

    /** `projects.json` del servidor. */
    var projects: List<Project> = emptyList()
    var projectsError: Exception? = null
    var saveError: Exception? = null
    var startError: Exception? = null
    var firstPanePaths: Map<String, String> = emptyMap()
    var firstPaneError: Exception? = null
    val savedProjects = mutableListOf<List<Project>>()

    override suspend fun listSessions(): List<TmuxSession> {
        calls += "list"
        listGate?.await()
        listError?.let { throw it }
        return sessions
    }

    override suspend fun disconnect() {
        disconnects++
    }

    override suspend fun isTmuxInstalled(): Boolean {
        calls += "isTmuxInstalled"
        tmuxCheckError?.let { throw it }
        return tmuxInstalled
    }

    override suspend fun canUseSudoNonInteractive(): Boolean = canSudo.also { calls += "canSudo" }

    override suspend fun installTmuxWithApt() {
        calls += "install"
        tmuxInstalled = true
    }

    override suspend fun tmuxConfigExists(): Boolean = configExists.also { calls += "configExists" }

    override suspend fun writeDefaultTmuxConfig() {
        calls += "writeConfig"
        configExists = true
    }

    override suspend fun enableClipboardForwarding() {
        calls += "clipboard"
    }

    override suspend fun createSession(name: String) {
        calls += "create:$name"
        managementError?.let { throw it }
        sessions = sessions + session(name)
    }

    override suspend fun renameSession(oldName: String, newName: String) {
        calls += "rename:$oldName->$newName"
        managementError?.let { throw it }
        sessions = sessions.map { if (it.name == oldName) it.copy(name = newName) else it }
    }

    override suspend fun killSession(name: String) {
        calls += "kill:$name"
        managementError?.let { throw it }
        sessions = sessions.filterNot { it.name == name }
    }

    override suspend fun loadProjects(): List<Project> {
        calls += "loadProjects"
        projectsError?.let { throw it }
        return projects
    }

    override suspend fun saveProjects(projects: List<Project>) {
        calls += "saveProjects"
        saveError?.let { throw it }
        this.projects = projects
        savedProjects += projects
    }

    override suspend fun sessionFirstPanePaths(): Map<String, String> {
        calls += "firstPanePaths"
        firstPaneError?.let { throw it }
        return firstPanePaths
    }

    override suspend fun startProject(sessionName: String, path: String, startupCommand: String?) {
        calls += "start:$sessionName|$path|$startupCommand"
        startError?.let { throw it }
        sessions = sessions + session(sessionName)
    }

    override suspend fun stopSession(sessionName: String) {
        calls += "stop:$sessionName"
        managementError?.let { throw it }
        sessions = sessions.filterNot { it.name == sessionName }
    }

    private fun unused(): Nothing = throw IOException("No usado todavía")

    /** Ventanas de la sesión (las operaciones las modifican como haría tmux). */
    var windows: List<TmuxWindow> = emptyList()
    var windowsError: Exception? = null
    var windowActionError: Exception? = null
    var installedAgents: Set<CodingAgent> = CodingAgent.entries.toSet()
    var listWindowsRequests = 0

    override suspend fun listWindows(session: String): List<TmuxWindow> {
        listWindowsRequests++
        windowsError?.let { throw it }
        return windows
    }

    override suspend fun selectWindow(session: String, index: Int) {
        calls += "selectWindow:$session:$index"
        windowActionError?.let { throw it }
        windows = windows.map { it.copy(isActive = it.index == index) }
    }

    override suspend fun newWindow(session: String) {
        calls += "newWindow:$session"
        windowActionError?.let { throw it }
        addWindow("zsh", "zsh")
    }

    override suspend fun newAgentWindow(session: String, agent: CodingAgent, directory: String?) {
        calls += "newAgentWindow:$session:${agent.rawValue}:$directory"
        windowActionError?.let { throw it }
        addWindow(agent.displayName, agent.binary)
    }

    private fun addWindow(name: String, command: String) {
        val index = (windows.maxOfOrNull { it.index } ?: 0) + 1
        windows = windows.map { it.copy(isActive = false) } + TmuxWindow(index, name, isActive = true, paneCount = 1, currentCommand = command)
    }

    override suspend fun installedCodingAgents(): Set<CodingAgent> = installedAgents
    override suspend fun gitBranch(path: String): String? = unused()
    override suspend fun renameWindow(session: String, index: Int, name: String) = unused()
    override suspend fun setWindowColor(session: String, index: Int, color: WindowColor?) = unused()
    override suspend fun killWindow(session: String, index: Int) {
        calls += "killWindow:$session:$index"
        windowActionError?.let { throw it }
        windows = windows.filterNot { it.index == index }
    }
    override suspend fun authorizeKey(line: String) = unused()
    override suspend fun revokeKey(comment: String) = unused()
    override suspend fun splitPane(session: String, vertical: Boolean) = unused()
    override suspend fun selectPane(session: String, direction: TmuxPaneDirection) = unused()
    override suspend fun zoomPane(session: String) = unused()
    override suspend fun killPane(session: String) = unused()
    override suspend fun sendKeys(session: String, keys: String, enter: Boolean) = unused()
    override suspend fun claudeHooksInstalled(): Boolean = unused()
    override suspend fun installClaudeHooks() = unused()
    override suspend fun uploadPastedFile(data: ByteArray, fileExtension: String): String = unused()
    override suspend fun uploadDroppedFile(data: ByteArray, originalName: String): String = unused()
    override suspend fun locateClaude(): String? = unused()
    override suspend fun killAgentProcess(pid: Int) = unused()
    override suspend fun availableMemoryKB(): Int? = unused()
    override suspend fun remoteDirectoryExists(path: String): Boolean = unused()
    override suspend fun runAgentScript(command: String): String = unused()
}
