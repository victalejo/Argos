package com.iaportafolio.argos.core.tmux

import com.iaportafolio.argos.core.SSHServiceError

/**
 * Interpretación pura de la salida de los comandos tmux (port de la lógica de
 * `SSHService.listSessions`, `listWindows`, `runManagementCommand`, `parseGitBranch` y la
 * clasificación de errores `indicatesNoTmuxServer` / `indicatesTmuxNotInstalled`).
 */
object TmuxOutputParser {
    private const val COMMAND_NOT_FOUND_EXIT_CODE = 127
    private const val NO_LIST_DETAIL = "tmux list-sessions no devolvió detalles."
    private const val NO_SERVER_DETAIL = "El servidor no devolvió detalles."

    /**
     * Mensajes con los que tmux indica "no hay servidor / sesiones" (varían según versión):
     * todos significan lista vacía, no error.
     */
    private val NO_SERVER_MARKERS = listOf(
        "no server running",
        "error connecting to",
        "failed to connect to server",
        "no sessions",
    )

    private fun haystack(stdout: String, stderr: String): String = "$stdout\n$stderr".lowercase()

    /** ¿La salida indica que no hay servidor tmux o no hay sesiones? */
    fun indicatesNoTmuxServer(stdout: String, stderr: String): Boolean {
        val text = haystack(stdout, stderr)
        return NO_SERVER_MARKERS.any { it in text }
    }

    /**
     * ¿El binario `tmux` no existe en el servidor? (exit 127 / "command not found"). Se comprueba
     * DESPUÉS de [indicatesNoTmuxServer] para no confundir ambos casos.
     */
    fun indicatesTmuxNotInstalled(stdout: String, stderr: String, exitCode: Int): Boolean {
        val text = haystack(stdout, stderr)
        if ("command not found" in text || "tmux: not found" in text) return true
        return exitCode == COMMAND_NOT_FOUND_EXIT_CODE && "tmux" in text
    }

    /**
     * Resultado de [TmuxCommands.LIST_SESSIONS]: sin servidor/sesiones → lista vacía; tmux
     * ausente → lanza [SSHServiceError.TmuxNotInstalled]; otro fallo → [SSHServiceError.CommandFailed].
     */
    fun parseListSessions(stdout: String, stderr: String, exitCode: Int): List<TmuxSession> {
        if (exitCode != 0) {
            if (indicatesNoTmuxServer(stdout, stderr)) return emptyList()
            if (indicatesTmuxNotInstalled(stdout, stderr, exitCode)) throw SSHServiceError.TmuxNotInstalled()
            throw SSHServiceError.CommandFailed(exitCode, stderr.trim().ifEmpty { NO_LIST_DETAIL })
        }
        return stdout.lineSequence().mapNotNull(TmuxSession::parse).toList()
    }

    /**
     * Resultado de [TmuxCommands.listWindows]: `[]` si falla (sesión inexistente o sin servidor;
     * la barra de ventanas queda vacía), si no, las ventanas ordenadas por índice.
     */
    fun parseListWindows(stdout: String, exitCode: Int): List<TmuxWindow> {
        if (exitCode != 0) return emptyList()
        return stdout.split("\n").mapNotNull(TmuxWindow::parse).sortedBy { it.index }
    }

    /**
     * Error de un comando de gestión: `null` si salió con 0; si no, [SSHServiceError.CommandFailed]
     * con el stderr de tmux (p. ej. nombre duplicado o sesión inexistente).
     */
    fun managementFailure(exitCode: Int, stderr: String): SSHServiceError.CommandFailed? =
        if (exitCode == 0) null else SSHServiceError.CommandFailed(exitCode, stderr.trim().ifEmpty { NO_SERVER_DETAIL })

    /**
     * Rama de la salida de [TmuxCommands.gitBranch]: última línea no vacía (el perfil del shell
     * puede ensuciar la primera); `null` si está vacía o es
     * `HEAD` (HEAD desacoplado: no hay rama). `exitCode != 0` → `null`.
     */
    fun parseGitBranch(output: String, exitCode: Int = 0): String? {
        if (exitCode != 0) return null
        val branch = output.lines().lastOrNull { it.isNotEmpty() }?.trim { it == ' ' || it == '\t' }.orEmpty()
        return branch.takeUnless { it.isEmpty() || it == "HEAD" }
    }
}
