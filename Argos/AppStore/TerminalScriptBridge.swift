//
//  TerminalScriptBridge.swift
//  Argos
//
//  «Abrir en Terminal con Claude Code» sin la excepción temporal de Apple Events
//  (canal Mac App Store). Es el mecanismo que Apple prevé para apps con sandbox:
//
//    1. El usuario instala UNA vez un AppleScript en
//       ~/Library/Application Scripts/<bundle id>/ con un panel de guardado (la app
//       no puede escribir ahí por su cuenta: solo el usuario).
//    2. Argos lo ejecuta con `NSUserAppleScriptTask`, que corre FUERA del sandbox, y
//       le pasa el comando con un Apple Event de subrutina.
//
//  macOS sigue pidiendo el permiso de Automatización (Argos → Terminal) la primera vez.
//

import AppKit
import Carbon
import OSAKit

enum TerminalScriptBridge {

    static let scriptFileName = "Abrir en Terminal.scpt"
    /// Handler del script. En el Apple Event el nombre va en minúsculas.
    static let handlerName = "abrir_en_terminal"
    /// Súbelo si cambia `scriptSource`: Argos pedirá reinstalar el script.
    static let scriptVersion = 1
    static let installedVersionKey = "terminalScriptVersion"

    static let scriptSource = """
    -- Argos: abre Terminal en la copia local de un proyecto y arranca Claude Code.
    -- Lo instalaste tú desde Argos (Ajustes → Permisos). Puedes borrarlo cuando quieras.

    on \(handlerName)(comando)
    \ttell application id "com.apple.Terminal"
    \t\tactivate
    \t\tdo script comando
    \tend tell
    end \(handlerName)

    on version_argos()
    \treturn \(scriptVersion)
    end version_argos
    """

    enum BridgeError: LocalizedError {
        case wrongDestination
        case compileFailed(String)

        var errorDescription: String? {
            switch self {
            case .wrongDestination:
                return "El script debe guardarse en la carpeta que propone Argos y con su nombre original."
            case .compileFailed(let detail):
                return "No se pudo instalar el script de Terminal: \(detail)"
            }
        }
    }

    // MARK: - Lógica pura

    /// Apple Event que invoca `handler(arguments…)` de un script de usuario.
    static func appleEvent(handler: String, arguments: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        return event
    }

    /// El usuario debe guardar en la carpeta de scripts de Argos y con el nombre esperado.
    static func isValidDestination(_ url: URL, scriptsDirectory: URL) -> Bool {
        let file = url.standardizedFileURL
        return file.lastPathComponent == scriptFileName
            && file.deletingLastPathComponent().path == scriptsDirectory.standardizedFileURL.path
    }

    // MARK: - Instalación

    static func scriptsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
    }

    static func scriptURL() throws -> URL {
        try scriptsDirectory().appendingPathComponent(scriptFileName)
    }

    static func isInstalled(defaults: UserDefaults = .standard) -> Bool {
        guard let url = try? scriptURL(), FileManager.default.fileExists(atPath: url.path) else { return false }
        return defaults.integer(forKey: installedVersionKey) == scriptVersion
    }

    /// Pide al usuario guardar el script (panel ya situado en la carpeta correcta).
    /// Devuelve `false` si cancela.
    @MainActor
    static func install(defaults: UserDefaults = .standard) throws -> Bool {
        let directory = try scriptsDirectory()
        let panel = NSSavePanel()
        panel.title = "Instalar el script de Terminal"
        panel.message = "Para abrir Terminal y arrancar Claude Code, Argos usa un pequeño AppleScript que "
            + "solo tú puedes instalar. Guárdalo en esta carpeta, sin cambiarle el nombre."
        panel.prompt = "Instalar"
        panel.directoryURL = directory
        panel.nameFieldStringValue = scriptFileName
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard isValidDestination(url, scriptsDirectory: directory) else { throw BridgeError.wrongDestination }

        let script = OSAScript(source: scriptSource, language: OSALanguage(forName: "AppleScript"))
        var error: NSDictionary?
        guard script.compileAndReturnError(&error), script.write(to: url, ofType: "scpt", error: &error) else {
            let detail = error?[OSAScriptErrorMessage] as? String ?? "error desconocido"
            throw BridgeError.compileFailed(detail)
        }
        defaults.set(scriptVersion, forKey: installedVersionKey)
        Log.store.info("Script de Terminal instalado (v\(scriptVersion))")
        return true
    }

    /// Muestra el script en Finder (para borrarlo: la app no puede hacerlo sola).
    @MainActor
    static func revealInFinder() {
        guard let url = try? scriptURL() else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let directory = try? scriptsDirectory() {
            NSWorkspace.shared.open(directory)
        }
    }

    // MARK: - Ejecución

    /// Abre Terminal y ejecuta `shellCommand` en una ventana nueva.
    static func run(shellCommand: String) async throws {
        let task = try NSUserAppleScriptTask(url: scriptURL())
        _ = try await task.execute(withAppleEvent: appleEvent(handler: handlerName, arguments: [shellCommand]))
    }
}
