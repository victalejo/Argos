//
//  PromptPasteScript.swift
//  ArgosCore
//
//  «Enviar ya» un prompt a la terminal de un proyecto (lógica pura): el texto ya está en
//  un archivo privado del servidor (subido por SFTP, nunca en la línea de comandos); el
//  script lo pega en el panel con `paste-buffer -p` (pegado entre corchetes, como la cola
//  de encargos), pulsa Enter y borra el archivo.
//
//  Solo pega si el panel está ejecutando Claude Code (lista PERMITIDA, no de prohibidos):
//  el texto lleva valores sacados de git ({rama}, {ultimo_commit}…) que controla quien
//  escribe en el repo, y pegarlo con Enter en un shell, un REPL (python, node, psql), un
//  `ssh` a otra máquina, vim o `sudo` los ejecutaría allí. Claude se reconoce por el
//  proceso en primer plano del panel: `claude` (o el título que se pone) o `node`/`bun`
//  lanzando Claude Code. `@argos_claude` no basta: queda puesto cuando Claude sale y el
//  panel vuelve al shell.
//
//  Y solo si Claude está LIBRE, releído justo antes de pegar: con un permiso pendiente
//  («Do you want to proceed?») el Enter final elegiría «Sí», y trabajando el texto se
//  mezclaría con lo que hace.
//

import Foundation

enum PromptPasteScript {
    static let outboxDirectory = ".config/argos/prompt-outbox"
    static let missingPaneExitCode = 3
    static let notClaudeExitCode = 4
    static let tmuxExitCode = 5
    static let busyExitCode = 6
    static let timeoutSeconds = 20
    /// Archivos del buzón más viejos que esto (de un envío que se cortó) se borran.
    static let staleMinutes = 10

    static func relativePath(token: String) -> String {
        "\(outboxDirectory)/\(token).txt"
    }

    /// `window` `nil` = la ventana activa de la sesión.
    static func command(session: String, window: Int?, relativePath: String) -> String {
        let target = ShellQuoting.singleQuoted(window.map { "=\(session):\($0)" } ?? "=\(session):")
        let file = "\"$HOME/\(relativePath)\""
        let script = """
        f=\(file)
        buf="argos-prompt-$$"
        trap 'rm -f -- "$f"; tmux -u delete-buffer -b "$buf" >/dev/null 2>&1' EXIT
        trap 'exit 1' INT TERM HUP
        find "$HOME/\(outboxDirectory)" -type f -name '*.txt' -mmin +\(staleMinutes) -exec rm -f -- {} + 2>/dev/null
        pane=$(tmux -u list-panes -t \(target) -F '#{pane_id} #{pane_active}' 2>/dev/null | awk '$2 == 1 { print $1; exit }')
        [ -n "$pane" ] || exit \(missingPaneExitCode)
        \(claudeCheck)
        \(busyCheck)
        is_claude "$pane" || exit \(notClaudeExitCode)
        claude_busy "$pane" && exit \(busyExitCode)
        tmux -u load-buffer -b "$buf" "$f" 2>/dev/null || exit \(tmuxExitCode)
        tmux -u paste-buffer -p -d -b "$buf" -t "$pane" 2>/dev/null || exit \(tmuxExitCode)
        sleep 1
        tmux -u send-keys -t "$pane" Enter 2>/dev/null || exit \(tmuxExitCode)
        exit 0
        """
        return RemoteTimeout.wrap(script, seconds: timeoutSeconds)
    }

    /// Borra el archivo del buzón si el script no llegó a ejecutarse (fallo de red).
    static func removeCommand(relativePath: String) -> String {
        "rm -f -- \"$HOME/\(relativePath)\""
    }

    /// `is_claude <panel>`: éxito solo si el proceso en primer plano del panel es Claude
    /// Code. Mira el argv del proceso en primer plano de su tty (`ps -t`, válido en Linux y
    /// macOS): `claude` (aunque sea un enlace a un binario con versión, que en macOS hace
    /// que `pane_current_command` muestre otro nombre) o `node`/`bun` lanzando Claude Code;
    /// un `node` a secas (REPL) no cuenta. Si `ps` no sirve (BusyBox), basta con que
    /// `pane_current_command` sea `claude`.
    static let claudeCheck = """
    is_claude() {
      c=$(tmux -u display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)
      [ "$c" = claude ] && return 0
      t=$(tmux -u display-message -p -t "$1" '#{pane_tty}' 2>/dev/null)
      [ -n "$t" ] || return 1
      ps -t "${t#/dev/}" -o stat= -o args= 2>/dev/null | awk '
        index($1, "+") {
          n = split($2, p, "/"); b = p[n]
          if (b == "claude") { f = 1; next }
          if (b != "node" && b != "nodejs" && b != "bun") next
          for (i = 3; i <= NF; i++) { m = split($i, q, "/"); if (q[m] == "claude" || index($i, "@anthropic-ai/claude-code/")) f = 1 }
        }
        END { exit !f }'
    }
    """

    /// `claude_busy <panel>`: éxito si Claude NO está libre, con las mismas señales que el
    /// sondeo (`claudeActivityCommand` + `ClaudePaneActivity.resolve`) y la cola de
    /// encargos: «esc to interrupt» en el pie o subagentes en segundo plano; el hook en
    /// `waiting`; el hook en `working` con el spinner a la vista (sin él, se interrumpió
    /// y está libre). Además, un diálogo de permiso o pregunta a la vista, aunque los
    /// hooks no estén instalados. Si no se puede leer la pantalla, se da por ocupado.
    static let busyCheck = """
    claude_busy() {
      o=$(tmux -u show-options -pqv -t "$1" @argos_claude 2>/dev/null)
      s=$(tmux -u capture-pane -p -t "$1" 2>/dev/null) || return 0
      s=$(printf '%s\\n' "$s" | grep -v '^[[:space:]]*$')
      printf '%s\\n' "$s" | tail -n 4 | grep -q 'esc to interrupt' && return 0
      printf '%s\\n' "$s" | grep -q '^[^ ]* Waiting for [0-9]* background' && return 0
      [ "$o" = waiting ] && return 0
      [ "$o" = working ] && printf '%s\\n' "$s" | grep -q '… ([0-9]' && return 0
      printf '%s\\n' "$s" | tail -n 15 | grep -Eq 'Do you want to|❯ *1[.] Yes' && return 0
      return 1
    }
    """
}

enum PromptSendError: LocalizedError, Equatable {
    case noPane
    case notClaude
    case busy
    case tmux
    case empty

    var errorDescription: String? {
        switch self {
        case .noPane:
            return String(localized: "La sesión del proyecto no está abierta: ábrela y vuelve a enviarlo.")
        case .notClaude:
            return String(localized: "En esa ventana no está Claude Code abierto: ábrelo y vuelve a enviarlo.")
        case .busy:
            return String(localized: "Claude está ocupado o esperando tu respuesta en esa ventana.")
        case .tmux:
            return String(localized: "No se pudo escribir en la ventana de tmux.")
        case .empty:
            return String(localized: "El encargo está vacío.")
        }
    }
}
