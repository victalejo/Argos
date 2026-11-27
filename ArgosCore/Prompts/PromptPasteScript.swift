//
//  PromptPasteScript.swift
//  ArgosCore
//
//  «Enviar ya» un prompt a la terminal de un proyecto (lógica pura): el texto ya está en
//  un archivo privado del servidor (subido por SFTP, nunca en la línea de comandos); el
//  script lo pega en el panel con `paste-buffer -p` (pegado entre corchetes, como la cola
//  de encargos), pulsa Enter y borra el archivo. Si en el panel hay un shell en vez de
//  Claude, NO pega: un texto de varias líneas se ejecutaría como órdenes.
//

import Foundation

enum PromptPasteScript {
    static let outboxDirectory = ".config/argos/prompt-outbox"
    static let missingPaneExitCode = 3
    static let shellOnlyExitCode = 4
    static let tmuxExitCode = 5
    static let timeoutSeconds = 20

    static func relativePath(token: String) -> String {
        "\(outboxDirectory)/\(token).txt"
    }

    /// `window` `nil` = la ventana activa de la sesión.
    static func command(session: String, window: Int?, relativePath: String) -> String {
        let target = ShellQuoting.singleQuoted(window.map { "=\(session):\($0)" } ?? "=\(session):")
        let file = "\"$HOME/\(relativePath)\""
        let script = """
        f=\(file)
        trap 'rm -f -- "$f"' EXIT
        pane=$(tmux -u list-panes -t \(target) -F '#{pane_id} #{pane_active}' 2>/dev/null | awk '$2 == 1 { print $1; exit }')
        [ -n "$pane" ] || exit \(missingPaneExitCode)
        c=$(tmux -u display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
        case "$c" in sh|bash|zsh|fish|dash|ksh|tcsh|csh|-sh|-bash|-zsh) exit \(shellOnlyExitCode) ;; esac
        buf="argos-prompt-$$"
        tmux -u load-buffer -b "$buf" "$f" 2>/dev/null || exit \(tmuxExitCode)
        tmux -u paste-buffer -p -d -b "$buf" -t "$pane" 2>/dev/null || exit \(tmuxExitCode)
        sleep 1
        tmux -u send-keys -t "$pane" Enter 2>/dev/null || exit \(tmuxExitCode)
        exit 0
        """
        return RemoteTimeout.wrap(script, seconds: timeoutSeconds)
    }
}

enum PromptSendError: LocalizedError, Equatable {
    case noPane
    case shellOnly
    case tmux
    case empty

    var errorDescription: String? {
        switch self {
        case .noPane:
            return String(localized: "La sesión del proyecto no está abierta: ábrela y vuelve a enviarlo.")
        case .shellOnly:
            return String(localized: "Claude no está abierto en la terminal del proyecto: arráncalo y vuelve a enviarlo.")
        case .tmux:
            return String(localized: "No se pudo escribir en la ventana de tmux.")
        case .empty:
            return String(localized: "El encargo está vacío.")
        }
    }
}
