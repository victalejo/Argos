package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.tmux.TmuxCommands

/**
 * Comandos remotos puros de proyectos (port de los estáticos de
 * `ArgosCore/Projects/SSHProjects.swift`). Strings IDÉNTICOS a los de Apple.
 *
 * El fichero de proyectos se lee/escribe con los comandos genéricos de `$HOME` (lectura con
 * `cat`, escritura privada y atómica con copia `.argos-backup`) sobre [PROJECTS_RELATIVE_PATH];
 * el contenido es [ProjectsFile.encoded].
 */
object ProjectCommands {

    /** Ruta del fichero de proyectos relativa al `$HOME` del servidor. */
    const val PROJECTS_RELATIVE_PATH = ".config/argos/projects.json"

    /** Exit code con el que [startProject] indica que la carpeta no existe. */
    const val MISSING_FOLDER_EXIT_CODE = 3

    /** Carpeta del primer panel de cada sesión; se parsea con [ProjectListing.firstPanePaths]. */
    const val FIRST_PANE_PATHS =
        "tmux list-panes -a -F '#{window_index}|#{pane_index}|#{pane_current_path}|#{session_name}' 2>/dev/null"

    private const val START_FAILED_MESSAGE = "No se pudo abrir el proyecto."

    /**
     * Crea la sesión del proyecto en su carpeta y teclea el comando de arranque en el shell
     * interactivo (con `send-keys`, así funcionan alias como `cc`).
     */
    fun startProject(sessionName: String, path: String, startupCommand: String?): String {
        val quotedPath = ShellQuoting.singleQuoted(path)
        val create = "[ -d $quotedPath ] || exit $MISSING_FOLDER_EXIT_CODE; " +
            "tmux new-session -d -s ${ShellQuoting.singleQuoted(sessionName)} -c $quotedPath"
        if (startupCommand == null) return create
        // `=nombre:` = ventana/panel activo de la sesión exacta.
        return create + " && tmux send-keys -t ${ShellQuoting.singleQuoted("=$sessionName:")} " +
            "${ShellQuoting.singleQuoted(startupCommand)} Enter"
    }

    /** Mata la sesión con target EXACTO (`'=nombre'`). */
    fun stopSession(sessionName: String): String = TmuxCommands.killSession(sessionName)

    /** Mensaje si [stopSession] falla sin stderr. */
    fun stopSessionFailureMessage(sessionName: String): String = "No se pudo detener la sesión '$sessionName'."

    /**
     * Error que corresponde al resultado de [startProject], o `null` si salió bien:
     * [ProjectError.MissingFolder] con [MISSING_FOLDER_EXIT_CODE]; si no,
     * [SSHServiceError.CommandFailed] con el stderr (o un mensaje genérico).
     */
    fun startProjectFailure(exitCode: Int, stderr: String, path: String): Exception? = when (exitCode) {
        0 -> null
        MISSING_FOLDER_EXIT_CODE -> ProjectError.MissingFolder(path)
        else -> SSHServiceError.CommandFailed(exitCode, stderr.trim().ifEmpty { START_FAILED_MESSAGE })
    }
}
