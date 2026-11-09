package com.iaportafolio.argos.core.tmux

import com.iaportafolio.argos.core.ShellQuoting

/**
 * Constructores puros de los comandos remotos de tmux (port de los estáticos y de los comandos
 * en línea de `SSHService.swift`, `SSHSessionManagement.swift`, `SSHTerminalSession.swift` y
 * `exactSessionTarget` de `Projects/SSHProjects.swift`).
 *
 * Los strings son IDÉNTICOS a los de Apple: los servidores son los mismos. Todo lo que viene
 * del usuario pasa por [ShellQuoting.singleQuoted].
 */
object TmuxCommands {

    // MARK: Sesiones

    /** Formato exacto de `tmux list-sessions -F` que parsea [TmuxSession.parse]. */
    const val SESSION_FORMAT = "#{session_name}|#{session_windows}|#{session_attached}|#{session_created}"

    const val LIST_SESSIONS = "tmux list-sessions -F '$SESSION_FORMAT'"

    /** Target EXACTO de sesión (`'=nombre'`): sin '=', tmux cae a coincidencia por prefijo. */
    fun exactSessionTarget(name: String): String = ShellQuoting.singleQuoted("=$name")

    /** `tmux new-session -d -s '<nombre>'` (sesión *detached*). */
    fun createSession(name: String): String = "tmux new-session -d -s ${ShellQuoting.singleQuoted(name)}"

    fun renameSession(oldName: String, newName: String): String =
        "tmux rename-session -t ${exactSessionTarget(oldName)} " + ShellQuoting.singleQuoted(newName)

    /** Destructivo; target exacto para no matar otra sesión por coincidencia de prefijo. */
    fun killSession(name: String): String = "tmux kill-session -t ${exactSessionTarget(name)}"

    /**
     * Comando que se lanza dentro del PTY para adjuntarse a la sesión. `-u` fuerza salida
     * UTF-8: la app no envía LANG/LC_* y en servidores sin locale (p. ej. macOS) tmux
     * pintaría acentos y símbolos como `_`.
     */
    fun attach(name: String): String = "tmux -u attach -t ${ShellQuoting.singleQuoted(name)}"

    // MARK: Ventanas

    /**
     * Formato de `list-windows` que parsea [TmuxWindow.parse]. El nombre va al final para
     * tolerar '|'; `@argos_color` es el color elegido y `pane_current_command` reconoce agentes.
     */
    const val LIST_WINDOWS_FORMAT =
        "#{window_index}|#{window_active}|#{window_panes}|#{@argos_color}|#{pane_current_command}|#{window_name}"

    fun listWindows(session: String): String =
        "tmux list-windows -t ${ShellQuoting.singleQuoted(session)} " +
            "-F ${ShellQuoting.singleQuoted(LIST_WINDOWS_FORMAT)}"

    fun selectWindow(session: String, index: Int): String =
        "tmux select-window -t ${ShellQuoting.singleQuoted(session)}:$index"

    /** `tmux new-window` en el directorio del panel activo (como `prefix c`), no en `~`. */
    fun newWindow(session: String): String =
        "tmux new-window -t ${ShellQuoting.singleQuoted(session)} -c '#{pane_current_path}'"

    fun renameWindow(session: String, index: Int, name: String): String =
        "tmux rename-window -t ${ShellQuoting.singleQuoted(session)}:$index " + ShellQuoting.singleQuoted(name)

    fun killWindow(session: String, index: Int): String =
        "tmux kill-window -t ${ShellQuoting.singleQuoted(session)}:$index"

    /** Guarda (o borra, con `null`) el color en la opción de usuario `@argos_color` de la ventana. */
    fun windowColor(session: String, index: Int, color: WindowColor?): String {
        val target = "${ShellQuoting.singleQuoted(session)}:$index"
        return if (color == null) {
            "tmux set-option -wu -t $target @argos_color"
        } else {
            "tmux set-option -w -t $target @argos_color ${ShellQuoting.singleQuoted(color.rawValue)}"
        }
    }

    /**
     * Nueva ventana con un agente: la crea con el nombre del agente en [directory] (o en el del
     * panel activo) y le teclea el binario en el shell interactivo (usa el PATH del usuario y, al
     * salir el agente, la ventana queda en su shell).
     */
    fun newAgentWindow(session: String, agent: CodingAgent, directory: String?): String {
        val target = ShellQuoting.singleQuoted(session)
        val dir = directory?.let(ShellQuoting::singleQuoted) ?: "'#{pane_current_path}'"
        return "idx=\$(tmux new-window -P -F '#{window_index}' -t $target -c $dir " +
            "-n ${ShellQuoting.singleQuoted(agent.displayName)}) && " +
            "tmux send-keys -t $target:\"\$idx\" ${ShellQuoting.singleQuoted(agent.binary)} Enter"
    }

    /** `git rev-parse --abbrev-ref HEAD` en [path] (ver [TmuxOutputParser.parseGitBranch]). */
    fun gitBranch(path: String): String =
        "git -C ${ShellQuoting.singleQuoted(path)} rev-parse --abbrev-ref HEAD 2>/dev/null"

    // MARK: Paneles (operan sobre el panel ACTIVO de la ventana actual)

    /** `vertical == true` apila arriba/abajo (`-v`); `false`, lado a lado (`-h`). */
    fun splitPane(session: String, vertical: Boolean): String =
        "tmux split-window ${if (vertical) "-v" else "-h"} -t ${ShellQuoting.singleQuoted(session)}"

    fun selectPane(session: String, direction: TmuxPaneDirection): String =
        "tmux select-pane ${direction.selectPaneFlag} -t ${ShellQuoting.singleQuoted(session)}"

    fun zoomPane(session: String): String = "tmux resize-pane -Z -t ${ShellQuoting.singleQuoted(session)}"

    fun killPane(session: String): String = "tmux kill-pane -t ${ShellQuoting.singleQuoted(session)}"

    // MARK: send-keys (broadcast)

    /**
     * `tmux send-keys`: el texto se entrecomilla y tmux lo TECLEA literal en el panel activo.
     * `enter` añade `Enter` como argumento aparte (sin comillas) para que sea una pulsación.
     */
    fun sendKeys(session: String, keys: String, enter: Boolean): String {
        val command = "tmux send-keys -t ${ShellQuoting.singleQuoted(session)} " + ShellQuoting.singleQuoted(keys)
        return if (enter) "$command Enter" else command
    }

    // MARK: Preparación del entorno (Ubuntu/Debian, no interactivo)

    const val WHOAMI = "whoami"

    /** Latido de keep-alive. */
    const val HEARTBEAT = "true"

    const val IS_TMUX_INSTALLED = "command -v tmux"

    /** `sudo -n` falla en vez de pedir contraseña: seguro en un canal sin TTY. */
    const val CAN_USE_SUDO_NON_INTERACTIVE = "sudo -n true"

    const val INSTALL_TMUX_WITH_APT =
        "sudo -n sh -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tmux'"

    /** Mensaje cuando tmux falta y no hay sudo sin contraseña (la app nunca pide la de sudo). */
    const val MANUAL_INSTALL_INSTRUCTION =
        "tmux no está instalado y tu usuario no tiene sudo sin contraseña. Instálalo con: sudo apt install tmux"

    const val TMUX_CONFIG_EXISTS = "test -f \"\$HOME/.tmux.conf\""

    /** Contenido base de `~/.tmux.conf` (mouse, scrollback, índices base 1, truecolor, OSC 52). */
    val DEFAULT_TMUX_CONFIG: String = listOf(
        "set -g mouse on",
        "set -g history-limit 50000",
        "set -g base-index 1",
        "setw -g pane-base-index 1",
        "set -g renumber-windows on",
        "set -sg escape-time 0",
        "set -g default-terminal \"tmux-256color\"",
        "set -ga terminal-overrides \",*256col*:Tc\"",
        "set -g set-clipboard on",
        "set -ga terminal-overrides \",*:Ms=\\\\E]52;%p1%s;%p2%s\\\\007\"",
    ).joinToString("\n")

    /** Crea `~/.tmux.conf` SOLO si no existe (idempotente; heredoc literal sin expansión). */
    val WRITE_DEFAULT_TMUX_CONFIG: String =
        "if [ ! -f \"\$HOME/.tmux.conf\" ]; then\n" +
            "cat > \"\$HOME/.tmux.conf\" <<'ARGOS_TMUX_CONF'\n" +
            DEFAULT_TMUX_CONFIG + "\n" +
            "ARGOS_TMUX_CONF\n" +
            "fi"

    /** Habilita OSC 52 en el servidor tmux EN EJECUCIÓN (best-effort, nunca falla). */
    const val ENABLE_CLIPBOARD_FORWARDING =
        "tmux set -g set-clipboard on 2>/dev/null; " +
            "tmux set -ga terminal-overrides ',*:Ms=\\E]52;%p1%s;%p2%s\\007' 2>/dev/null; true"
}
