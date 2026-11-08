package com.iaportafolio.argos.core

import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.core.tmux.TmuxPaneDirection
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.core.tmux.WindowColor

/**
 * Contrato del servicio SSH/tmux (port de `ArgosCore/SSHServicing.swift`), para inyectar la
 * implementación real (sshj, módulo `ssh`) o un doble en los tests. Solo el contrato: aquí no
 * hay nada de SSH.
 *
 * Los errores se lanzan como excepciones tipadas ([SSHServiceError], validadores de
 * `core.tmux`), igual que los `throws` de Apple.
 *
 * Por ahora cubre la parte de tmux y los miembros cuyos tipos ya existen en este paquete. Las
 * operaciones que dependen de tipos de otros paquetes (archivos/SFTP, sincronización, monitor,
 * estado de Claude, claves autorizadas y los canales PTY/exec en streaming) se
 * añadirán al integrarlos.
 */
interface SSHServicing {
    suspend fun listSessions(): List<TmuxSession>
    suspend fun disconnect()

    // Preparación del entorno tmux
    suspend fun isTmuxInstalled(): Boolean
    suspend fun canUseSudoNonInteractive(): Boolean
    suspend fun installTmuxWithApt()
    suspend fun tmuxConfigExists(): Boolean
    suspend fun writeDefaultTmuxConfig()

    /** Best-effort: nunca lanza. */
    suspend fun enableClipboardForwarding()

    // Sesiones
    suspend fun createSession(name: String)
    suspend fun renameSession(oldName: String, newName: String)
    suspend fun killSession(name: String)

    // Ventanas
    suspend fun listWindows(session: String): List<TmuxWindow>
    suspend fun selectWindow(session: String, index: Int)
    suspend fun newWindow(session: String)

    /** Abre una ventana nueva con un agente de terminal (Claude Code, Codex, Grok). */
    suspend fun newAgentWindow(session: String, agent: CodingAgent, directory: String?)

    /** Agentes de terminal instalados en el servidor. */
    suspend fun installedCodingAgents(): Set<CodingAgent>

    /** Rama git de [path] en el servidor (`null` si no es un repositorio). */
    suspend fun gitBranch(path: String): String?
    suspend fun renameWindow(session: String, index: Int, name: String)
    suspend fun setWindowColor(session: String, index: Int, color: WindowColor?)
    suspend fun killWindow(session: String, index: Int)

    // Claves autorizadas
    /** Añade una línea a `~/.ssh/authorized_keys` del servidor. */
    suspend fun authorizeKey(line: String)

    /** Retira de `authorized_keys` las líneas con ese comentario. */
    suspend fun revokeKey(comment: String)

    // Paneles
    suspend fun splitPane(session: String, vertical: Boolean)
    suspend fun selectPane(session: String, direction: TmuxPaneDirection)
    suspend fun zoomPane(session: String)
    suspend fun killPane(session: String)

    suspend fun sendKeys(session: String, keys: String, enter: Boolean)

    // Hooks de Claude
    suspend fun claudeHooksInstalled(): Boolean
    suspend fun installClaudeHooks()

    // Proyectos (carpetas con sesión tmux efímera)
    /**
     * Proyectos de `~/.config/argos/projects.json` (fichero inexistente = lista vacía). Lanza
     * [com.iaportafolio.argos.core.projects.ProjectError.InvalidFile] si no es válido.
     */
    suspend fun loadProjects(): List<Project>

    /** Reescribe `projects.json` (privado, atómico y con copia `.argos-backup`). */
    suspend fun saveProjects(projects: List<Project>)

    /** Carpeta del primer panel de cada sesión (nombre de sesión → ruta). */
    suspend fun sessionFirstPanePaths(): Map<String, String>
    suspend fun startProject(sessionName: String, path: String, startupCommand: String?)
    suspend fun stopSession(sessionName: String)

    // Subidas al servidor
    /** Sube datos pegados y devuelve la ruta remota. */
    suspend fun uploadPastedFile(data: ByteArray, fileExtension: String): String

    /** Sube un archivo soltado y devuelve la ruta remota. */
    suspend fun uploadDroppedFile(data: ByteArray, originalName: String): String

    // Panel de agente (Claude Code)
    /** Ruta absoluta del binario `claude` en el servidor, o `null` si no está. */
    suspend fun locateClaude(): String?

    /** Mata el `claude` de un agente (verificando que el PID sigue siendo un agente). */
    suspend fun killAgentProcess(pid: Int)

    /** Memoria disponible del servidor en KB (`null` si no se puede saber). */
    suspend fun availableMemoryKB(): Int?

    /** ¿[path] existe como directorio en el servidor? */
    suspend fun remoteDirectoryExists(path: String): Boolean

    /** Comando corto del agente persistente; devuelve stdout y lanza si el código no es 0. */
    suspend fun runAgentScript(command: String): String
}
