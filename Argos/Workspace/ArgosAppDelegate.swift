//
//  ArgosAppDelegate.swift
//  Argos
//
//  Ciclo de vida de la app del Mac:
//  - Dueño del modelo único (`ArgosAppModel`): la ventana va y viene, el estado no.
//  - Ventana única y sin pestañas de ventana («Mostrar barra de pestañas» → «+» creaba
//    una segunda ventana con su propio estado).
//  - Cerrar la ventana NO cierra la app: sigue avisando y con sus terminales, agentes y
//    túneles; se reabre desde el Dock o el menú Ventana tal como estaba.
//  - Al salir: si hay agentes trabajando o envíos en curso, se pide confirmación; luego,
//    con un plazo de `shutdownTimeout`, se detienen los agentes del panel, se cierran los
//    túneles y se desenganchan los terminales. Nada de lo que corre en tmux se mata.
//

import AppKit

@MainActor
final class ArgosAppDelegate: NSObject, NSApplicationDelegate {
    let model: ArgosAppModel

    /// Plazo del cierre ordenado antes de salir igualmente.
    static let shutdownTimeout: Duration = .seconds(5)

    private var isTerminating = false

    override init() {
        model = ArgosAppModel()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// El sondeo y los avisos no dependen de que la ventana llegue a mostrarse.
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        if let message = model.workInProgress.message, !confirmQuit(message) {
            return .terminateCancel
        }
        isTerminating = true
        Task { @MainActor in
            await model.shutdown(within: Self.shutdownTimeout)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuit(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "¿Salir de Argos?"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Salir")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
