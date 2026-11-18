//
//  ArgosAppDelegate.swift
//  Argos
//
//  Ciclo de vida de la app del Mac:
//  - Dueño del modelo único (`ArgosAppModel`): la ventana va y viene, el estado no.
//  - Ventana única y sin pestañas de ventana («Mostrar barra de pestañas» → «+» creaba
//    una segunda ventana con su propio estado).
//  - Cerrar la ventana NO cierra la app: sigue avisando y con sus terminales, agentes y
//    túneles; el Dock (`applicationShouldHandleReopen`), el menú Ventana, la barra de
//    menús y los avisos la vuelven a abrir tal como estaba.
//  - Al salir: si hay agentes trabajando o envíos en curso, se pide confirmación (no al
//    cerrar sesión o apagar el sistema); luego, con un plazo de `shutdownTimeout`, se
//    detienen los agentes del panel, se cierran los túneles y se desenganchan los
//    terminales. Nada de lo que corre en tmux se mata.
//

import AppKit

@MainActor
final class ArgosAppDelegate: NSObject, NSApplicationDelegate {
    let model: ArgosAppModel

    /// Plazo del cierre ordenado antes de salir igualmente.
    static let shutdownTimeout: Duration = .seconds(5)

    private lazy var termination = TerminationCoordinator(
        workInProgress: { [model = self.model] in model.workInProgress },
        isSystemSessionEnding: { Self.isSystemSessionEnding },
        confirm: { Self.confirmQuit($0) },
        shutdown: { [model = self.model] in await model.shutdown(within: Self.shutdownTimeout) },
        reply: { NSApp.reply(toApplicationShouldTerminate: $0) }
    )

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

    /// Clic en el Dock sin ventana a la vista: se reabre la principal.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        model.showMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch termination.shouldTerminate() {
        case .cancel: return .terminateCancel
        case .later: return .terminateLater
        }
    }

    // MARK: - Utilidades

    /// La salida viene de cerrar sesión, reiniciar o apagar (no se pregunta nada).
    private static var isSystemSessionEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let systemReasons: [OSType] = [
            OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
            OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown),
        ]
        return systemReasons.contains(reason)
    }

    private static func confirmQuit(_ message: String) -> Bool {
        // Desde el Dock con la app detrás, el diálogo quedaría oculto.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "¿Salir de Argos?"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Salir")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
