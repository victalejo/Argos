//
//  LocalTerminalLauncher.swift
//  Argos
//
//  Abre la copia local de un proyecto en Terminal con Claude Code arrancado. Usa Apple
//  Events («do script»), así que macOS pide permiso la primera vez. Si se deniega, abre
//  Terminal en la carpeta sin ejecutar nada, y el usuario solo tiene que escribir `claude`.
//

import AppKit

enum LocalTerminalLauncher {

    static let terminalBundleID = "com.apple.Terminal"
    static let claudeBinary = "claude --dangerously-skip-permissions"

    /// Comando que reanuda la conversación MÁS RECIENTE del proyecto por su ID, o arranca
    /// una nueva si no hay.
    ///
    /// Claude guarda las conversaciones en `~/.claude/projects/<ruta con cada carácter no
    /// alfanumérico cambiado por '-'>/<id>.jsonl`, según la carpeta donde se abrió. La copia
    /// del Mac puede vivir en otra ruta que en el servidor (p. ej. `~/Desarrollo/entrelingo/x`
    /// frente a `~/Desarrollo/x`), así que se busca en AMBAS: si la más reciente está en la
    /// de la ruta del servidor, se copia a la de la carpeta local (`--resume` solo encuentra
    /// las de la carpeta actual; se sobrescribe la copia, porque la elegida es la más
    /// reciente). Se reanuda por ID y no con el selector, porque el selector
    /// solo lista las conversaciones de la cuenta logueada.
    /// Sin globs de shell (`*.jsonl`): en zsh, sin coincidencias, abortan la línea.
    static func claudeCommand(remoteRoot: String? = nil) -> String {
        let remote = remoteRoot.map { ShellQuoting.singleQuoted($0) } ?? "\"$PWD\""
        return """
            P="$HOME/.claude/projects"; \
            L="$P/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"; \
            R="$P/$(printf '%s' \(remote) | sed 's/[^A-Za-z0-9]/-/g')"; \
            s=$(find "$L" "$R" -maxdepth 1 -name '*.jsonl' -exec ls -t {} + 2>/dev/null | head -n 1); \
            if [ -n "$s" ] && [ "$(dirname "$s")" != "$L" ]; then \
            mkdir -p "$L" && cp "$s" "$L/"; \
            [ -d "${s%.jsonl}" ] && cp -R "${s%.jsonl}" "$L/"; fi; \
            if [ -n "$s" ]; then \(claudeBinary) --resume "$(basename "$s" .jsonl)"; \
            else \(claudeBinary); fi
            """
    }

    enum Outcome: Equatable {
        /// Terminal abierto con `claude` en marcha.
        case launched
        /// Sin permiso de automatización: Terminal abierto en la carpeta, sin `claude`.
        case openedFolderOnly
        case failed(String)
    }

    /// AppleScript que abre una ventana de Terminal en `folder` y ejecuta `command`.
    /// Dos capas de escape: la ruta va entre comillas de shell, y todo el comando va
    /// dentro de una cadena de AppleScript (donde `\` y `"` se escapan).
    static func script(folder: String, command: String = claudeCommand()) -> String {
        let shell = "cd \(ShellQuoting.singleQuoted(folder)) && \(command)"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application id "\(terminalBundleID)"
            activate
            do script "\(escaped)"
        end tell
        """
    }

    @MainActor
    static func openWithClaude(_ folder: URL, remoteRoot: String? = nil) -> Outcome {
        var error: NSDictionary?
        let command = claudeCommand(remoteRoot: remoteRoot)
        NSAppleScript(source: script(folder: folder.path, command: command))?.executeAndReturnError(&error)
        guard let error else { return .launched }

        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        Log.store.error("No se pudo abrir Terminal con Claude Code (Apple Event \(code)): \(String(describing: error[NSAppleScript.errorMessage]), privacy: .public)")
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            return .failed("No se encontró la app Terminal.")
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return .openedFolderOnly
    }

    /// Mensaje para la UI (nil si todo fue bien).
    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .launched:
            return nil
        case .openedFolderOnly:
            return "Terminal se abrió en la carpeta, pero Argos no tiene permiso para escribir en él. "
                + "Escribe «claude --resume», o actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización."
        case .failed(let message):
            return message
        }
    }
}
