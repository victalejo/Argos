package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.TerminalControlEvent
import com.iaportafolio.argos.core.TerminalStreaming
import com.iaportafolio.argos.core.agent.AgentExecCommands
import com.iaportafolio.argos.core.agent.AgentExecException
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.PersistentAgentException
import com.iaportafolio.argos.core.agent.PersistentAgentError
import com.iaportafolio.argos.core.agent.RemoteDirectoryListing
import com.iaportafolio.argos.core.files.RemoteFileBrowsing
import com.iaportafolio.argos.core.files.RemoteFileContent
import com.iaportafolio.argos.core.files.RemoteFileEntry
import com.iaportafolio.argos.core.git.GitOperations
import com.iaportafolio.argos.core.keys.AuthorizedKeysCommands
import com.iaportafolio.argos.core.keys.RemoteHomeFileCommands
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectCommands
import com.iaportafolio.argos.core.projects.ProjectListing
import com.iaportafolio.argos.core.projects.ProjectsFile
import com.iaportafolio.argos.core.status.ClaudeHookInstaller
import com.iaportafolio.argos.core.status.ClaudeStatusCommands
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.core.tmux.TmuxCommands
import com.iaportafolio.argos.core.tmux.TmuxOutputParser
import com.iaportafolio.argos.core.tmux.TmuxPaneDirection
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.core.tmux.WindowColor
import com.iaportafolio.argos.core.tmux.WindowNameValidator
import kotlinx.coroutines.flow.Flow
import java.io.OutputStream
import kotlin.coroutines.cancellation.CancellationException

/**
 * [SSHServicing] sobre sshj (port de `SSHService.swift` + `SSHSessionManagement.swift`,
 * `SSHKeyAuthorization.swift`, `Projects/SSHProjects.swift`, `ClaudeStatus/SSHClaudeStatus.swift`,
 * `RemotePrivateFile.swift`, `SSHFileTransfer.swift` y la parte no-streaming de
 * `Agent/SSHAgentExec.swift`).
 *
 * Cada operación es un comando corto por el CANAL DE COMANDOS (exec), con los comandos y
 * parsers de `core`: byte a byte los de Apple, porque los servidores son los mismos.
 *
 * También es [TerminalStreaming] (port de `SSHTerminalSession.swift`): cada terminal en vivo
 * es un canal PTY propio sobre la MISMA conexión ([SshjTerminal]), en paralelo a la gestión.
 *
 * Y es [RemoteFileBrowsing] (port de `Files/SSHFileBrowser.swift`): explorador de solo lectura
 * por SFTP con un cliente SFTP reutilizado por conexión ([SshjFileBrowser]).
 *
 * Y es [AgentExecStreaming] (resto de `Agent/SSHAgentExec.swift`): canal exec sin PTY para lanzar
 * el agente y seguir su log, cada uno en una conexión dedicada ([SshjAgentExec]).
 *
 * Y es [GitOperations] (port de `Git/SSHGit.swift`): el panel «Cambios» con comandos git cortos
 * por el canal de comandos ([SshjGit]).
 */
class SshjSSHService internal constructor(private val connection: SshjConnection) :
    SSHServicing,
    TerminalStreaming,
    RemoteFileBrowsing,
    AgentExecStreaming,
    GitOperations by SshjGit(connection) {

    private val terminal = SshjTerminal(connection)
    private val files = SshjFileBrowser(connection)
    private val agentExec = SshjAgentExec(connection)

    // MARK: Canal exec del agente

    override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) =
        agentExec.run(command, stdin, output)

    override suspend fun claudeAuthStatus(): ClaudeAuthStatus? {
        val claudePath = locateClaude() ?: return null
        return AgentExecCommands.parseAuthStatus(connection.capture(AgentExecCommands.claudeAuthStatus(claudePath)).stdout)
    }

    // MARK: Explorador de archivos (SFTP)

    override suspend fun listRemoteDirectory(path: String, root: String): List<RemoteFileEntry> =
        files.listRemoteDirectory(path, root)

    override suspend fun readRemoteFile(path: String, root: String, maxBytes: Long): RemoteFileContent =
        files.readRemoteFile(path, root, maxBytes)

    override suspend fun downloadRemoteFile(path: String, root: String, destination: OutputStream): Long =
        files.downloadRemoteFile(path, root, destination)

    override suspend fun indexProjectFiles(root: String): List<String> = files.indexProjectFiles(root)

    override suspend fun listRemoteDirectories(path: String): RemoteDirectoryListing =
        files.listRemoteDirectories(path)

    // MARK: Terminal en vivo

    override suspend fun attachTerminal(
        session: String,
        initialCols: Int,
        initialRows: Int,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    ) = terminal.run(TmuxCommands.attach(session), initialCols, initialRows, control, output)

    override suspend fun attachCommand(
        command: String,
        initialCols: Int,
        initialRows: Int,
        control: Flow<TerminalControlEvent>,
        output: suspend (ByteArray) -> Unit,
    ) = terminal.run(command, initialCols, initialRows, control, output)

    // MARK: Sesiones

    override suspend fun listSessions(): List<TmuxSession> {
        val result = connection.capture(TmuxCommands.LIST_SESSIONS)
        return TmuxOutputParser.parseListSessions(result.stdout, result.stderr, result.exitCode)
    }

    override suspend fun disconnect() {
        files.close()
        connection.disconnect()
    }

    /**
     * Prueba la conexión (host key + autenticación) y devuelve el usuario remoto (`whoami`).
     * Para el botón «Probar conexión»: el llamador hace [disconnect] después.
     */
    suspend fun testConnection(): String = connection.capture(TmuxCommands.WHOAMI).stdout.trim()

    override suspend fun createSession(name: String) = runManagement(TmuxCommands.createSession(name))

    override suspend fun renameSession(oldName: String, newName: String) =
        runManagement(TmuxCommands.renameSession(oldName, newName))

    override suspend fun killSession(name: String) = runManagement(TmuxCommands.killSession(name))

    // MARK: Preparación del entorno tmux

    override suspend fun isTmuxInstalled(): Boolean = succeeds(TmuxCommands.IS_TMUX_INSTALLED)

    override suspend fun canUseSudoNonInteractive(): Boolean = succeeds(TmuxCommands.CAN_USE_SUDO_NON_INTERACTIVE)

    override suspend fun installTmuxWithApt() {
        val result = connection.capture(TmuxCommands.INSTALL_TMUX_WITH_APT)
        // Verificación independiente del código de salida de apt.
        if (!isTmuxInstalled()) {
            throw SSHServiceError.InstallFailed(result.stderr.trim().ifEmpty { "apt terminó con código ${result.exitCode}." })
        }
    }

    override suspend fun tmuxConfigExists(): Boolean = succeeds(TmuxCommands.TMUX_CONFIG_EXISTS)

    override suspend fun writeDefaultTmuxConfig() {
        val result = connection.capture(TmuxCommands.WRITE_DEFAULT_TMUX_CONFIG)
        if (result.exitCode != 0) {
            throw SSHServiceError.ConfigFailed(result.stderr.trim().ifEmpty { "Código de salida ${result.exitCode}." })
        }
    }

    override suspend fun enableClipboardForwarding() {
        bestEffort { connection.capture(TmuxCommands.ENABLE_CLIPBOARD_FORWARDING) }
    }

    // MARK: Ventanas

    override suspend fun listWindows(session: String): List<TmuxWindow> {
        val result = connection.capture(TmuxCommands.listWindows(session))
        return TmuxOutputParser.parseListWindows(result.stdout, result.exitCode)
    }

    override suspend fun selectWindow(session: String, index: Int) =
        runManagement(TmuxCommands.selectWindow(session, index))

    override suspend fun newWindow(session: String) = runManagement(TmuxCommands.newWindow(session))

    override suspend fun newAgentWindow(session: String, agent: CodingAgent, directory: String?) =
        runManagement(TmuxCommands.newAgentWindow(session, agent, directory))

    override suspend fun installedCodingAgents(): Set<CodingAgent> =
        CodingAgent.parseInstalled(connection.capture(posixShell(CodingAgent.installedAgentsScript)).stdout)

    override suspend fun gitBranch(path: String): String? {
        val result = connection.capture(TmuxCommands.gitBranch(path))
        return TmuxOutputParser.parseGitBranch(result.stdout, result.exitCode)
    }

    override suspend fun renameWindow(session: String, index: Int, name: String) {
        val validName = WindowNameValidator.validate(name)
        runManagement(TmuxCommands.renameWindow(session, index, validName))
    }

    override suspend fun setWindowColor(session: String, index: Int, color: WindowColor?) =
        runManagement(TmuxCommands.windowColor(session, index, color))

    override suspend fun killWindow(session: String, index: Int) =
        runManagement(TmuxCommands.killWindow(session, index))

    // MARK: Claves autorizadas

    override suspend fun authorizeKey(line: String) = runManagement(AuthorizedKeysCommands.authorizeKey(line))

    override suspend fun revokeKey(comment: String) = runManagement(AuthorizedKeysCommands.revokeKey(comment))

    // MARK: Paneles

    override suspend fun splitPane(session: String, vertical: Boolean) =
        runManagement(TmuxCommands.splitPane(session, vertical))

    override suspend fun selectPane(session: String, direction: TmuxPaneDirection) =
        runManagement(TmuxCommands.selectPane(session, direction))

    override suspend fun zoomPane(session: String) = runManagement(TmuxCommands.zoomPane(session))

    override suspend fun killPane(session: String) = runManagement(TmuxCommands.killPane(session))

    override suspend fun sendKeys(session: String, keys: String, enter: Boolean) =
        runManagement(TmuxCommands.sendKeys(session, keys, enter))

    // MARK: Hooks de Claude

    override suspend fun claudeHooksInstalled(): Boolean = ClaudeHookInstaller.isInstalled(readClaudeSettings())

    /** settings.json puede contener secretos: se escribe privado (600), atómico y con copia. */
    override suspend fun installClaudeHooks() {
        val merged = ClaudeHookInstaller.installing(readClaudeSettings())
        val content = ClaudeHookInstaller.serialize(merged).toByteArray(Charsets.UTF_8)
        writeHomeFilePrivately(content, ClaudeStatusCommands.CLAUDE_SETTINGS_RELATIVE_PATH, backup = true)
    }

    private suspend fun readClaudeSettings() =
        ClaudeHookInstaller.parseSettings(readHomeFile(ClaudeStatusCommands.CLAUDE_SETTINGS_RELATIVE_PATH))

    // MARK: Proyectos

    override suspend fun loadProjects(): List<Project> =
        ProjectsFile.decode(readHomeFile(ProjectCommands.PROJECTS_RELATIVE_PATH)).projects

    override suspend fun saveProjects(projects: List<Project>) {
        val data = ProjectsFile(projects = projects).encoded()
        writeHomeFilePrivately(data, ProjectCommands.PROJECTS_RELATIVE_PATH, backup = true)
    }

    override suspend fun sessionFirstPanePaths(): Map<String, String> {
        val result = connection.capture(ProjectCommands.FIRST_PANE_PATHS)
        return if (result.exitCode == 0) ProjectListing.firstPanePaths(result.stdout) else emptyMap()
    }

    override suspend fun startProject(sessionName: String, path: String, startupCommand: String?) {
        val result = connection.capture(ProjectCommands.startProject(sessionName, path, startupCommand))
        ProjectCommands.startProjectFailure(result.exitCode, result.stderr, path)?.let { throw it }
    }

    override suspend fun stopSession(sessionName: String) {
        runChecked(ProjectCommands.stopSession(sessionName), ProjectCommands.stopSessionFailureMessage(sessionName))
    }

    // MARK: Subidas

    override suspend fun uploadPastedFile(data: ByteArray, fileExtension: String): String =
        connection.upload(data, UploadPaths.pasted(fileExtension, System.currentTimeMillis()))

    override suspend fun uploadDroppedFile(data: ByteArray, originalName: String): String =
        connection.upload(data, UploadPaths.dropped(originalName, System.currentTimeMillis()))

    // MARK: Panel de agente

    override suspend fun locateClaude(): String? =
        AgentExecCommands.parseLocateClaude(connection.capture(AgentExecCommands.LOCATE_CLAUDE_SCRIPT).stdout)

    override suspend fun killAgentProcess(pid: Int) {
        bestEffort { connection.capture(AgentExecCommands.killAgentProcess(pid)) }
    }

    override suspend fun availableMemoryKB(): Int? =
        AgentExecCommands.parseAvailableMemoryKB(connection.capture(AgentExecCommands.AVAILABLE_MEMORY_COMMAND).stdout)
            ?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }
            ?.toInt()

    override suspend fun remoteDirectoryExists(path: String): Boolean = AgentExecCommands.parseRemoteDirectoryExists(
        connection.capture(AgentExecCommands.remoteDirectoryExists(path)).stdout,
    )

    override suspend fun runAgentScript(command: String): String {
        // Bajo `sh`: con zsh como shell de login, el comodín del listado sin agentes abortaría.
        val result = connection.capture(posixShell(command))
        if (result.exitCode == 0) return result.stdout
        val detail = result.stderr.trim()
        if (AgentExecCommands.isAgentDead(detail)) throw PersistentAgentException(PersistentAgentError.NOT_RUNNING)
        throw AgentExecException(if (detail.isEmpty()) "código de salida ${result.exitCode}" else detail.takeLast(AGENT_DETAIL_LIMIT))
    }

    // MARK: Ficheros privados en $HOME (port de RemotePrivateFile.swift)

    /** Contenido de `~/<relativePath>`, o `""` si no existe. */
    private suspend fun readHomeFile(relativePath: String): String {
        val result = connection.capture(RemoteHomeFileCommands.read(relativePath))
        return if (result.exitCode == 0) result.stdout else ""
    }

    /**
     * Escribe [data] en `~/<relativePath>` de forma privada (umask 077) y atómica (temporal +
     * `mv`). El contenido viaja por SFTP, nunca en la línea de comandos.
     */
    private suspend fun writeHomeFilePrivately(data: ByteArray, relativePath: String, backup: Boolean) {
        val failure = "No se pudo escribir ~/$relativePath."
        val home = runChecked(RemoteHomeFileCommands.prepareWrite(relativePath, backup), failure)
        val tempPath = RemoteHomeFileCommands.tempUploadPath(home, relativePath)
            ?: throw SSHServiceError.CommandFailed(0, "No se pudo resolver \$HOME en el servidor.")
        connection.upload(data, tempPath, exclusive = false)
        runChecked(RemoteHomeFileCommands.commitWrite(relativePath), failure)
    }

    // MARK: Ejecución

    /** Comando de gestión: código distinto de 0 → [SSHServiceError.CommandFailed] con el stderr. */
    private suspend fun runManagement(command: String) {
        val result = connection.capture(command)
        TmuxOutputParser.managementFailure(result.exitCode, result.stderr)?.let { throw it }
    }

    /** Ejecuta y devuelve stdout; lanza [SSHServiceError.CommandFailed] si sale con error. */
    private suspend fun runChecked(command: String, failureMessage: String): String {
        val result = connection.capture(command)
        if (result.exitCode != 0) {
            throw SSHServiceError.CommandFailed(result.exitCode, result.stderr.trim().ifEmpty { failureMessage })
        }
        return result.stdout
    }

    private suspend fun succeeds(command: String): Boolean = connection.capture(command).exitCode == 0

    /** Operación best-effort (como los `try?` de Apple): nunca lanza, salvo la cancelación. */
    private suspend fun bestEffort(block: suspend () -> Unit) {
        try {
            block()
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Exception) {
            // Sin conexión, canal caído o error de autenticación: se ignora a propósito.
        }
    }

    private companion object {
        /** Apple muestra los últimos 600 caracteres del stderr del agente. */
        const val AGENT_DETAIL_LIMIT = 600
    }
}
