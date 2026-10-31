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
    static let claudeCommand = "claude"

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
    static func script(folder: String, command: String = claudeCommand) -> String {
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
    static func openWithClaude(_ folder: URL) -> Outcome {
        var error: NSDictionary?
        NSAppleScript(source: script(folder: folder.path))?.executeAndReturnError(&error)
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
                + "Escribe «claude», o actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización."
        case .failed(let message):
            return message
        }
    }
}
