//
//  WindowCommands.swift
//  Argos
//
//  Menú Ventana → «Mostrar la ventana de Argos» y el puente que permite al modelo abrir
//  la ventana principal aunque esté cerrada: `openWindow` solo existe en el entorno de
//  SwiftUI, y los `Commands` viven tanto como la app (la ventana no).
//

import SwiftUI

struct WindowCommands: Commands {
    let model: ArgosAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = register()
        CommandGroup(before: .windowList) {
            Button("Mostrar la ventana de Argos") { model.showMainWindow() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
        }
    }

    /// Deja al modelo la forma de abrir la ventana (idempotente; no toca estado observado).
    private func register() {
        let open = openWindow
        model.windowOpener = { open(id: ArgosAppModel.mainWindowID) }
    }
}
