//
//  ArgosApp.swift
//  Argos
//
//  Gestor visual de sesiones tmux remotas vía SSH.
//

import AppKit
import Sparkle
import SwiftUI

@main
struct ArgosApp: App {
    // Sparkle: controlador del actualizador (OTA). `startingUpdater: true` arranca los
    // chequeos programados en segundo plano (gobernados por SUEnableAutomaticChecks).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // "Buscar actualizaciones…" de Sparkle, junto a "Acerca de". Sparkle muestra
            // su propia UI (disponible / al día / error / progreso / instalar y reiniciar).
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            // El terminal de SwiftTerm implementa copy:/paste:/selectAll: como acciones
            // estándar de AppKit, pero sin estos ítems de menú (con sus atajos) las teclas
            // Cmd+C/Cmd+V se enviarían como bytes crudos al PTY en vez de tocar el
            // portapapeles del Mac. Enrutamos al first responder con `sendAction(to: nil)`.
            CommandGroup(replacing: .pasteboard) {
                Button("Cortar") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Copiar") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Pegar") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Seleccionar todo") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }
        }

        Settings {
            TerminalSettingsView()
        }
    }
}
