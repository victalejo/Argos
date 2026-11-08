//
//  ArgosApp.swift
//  Argos
//
//  Gestor visual de sesiones tmux remotas vía SSH.
//

import AppKit
#if !APPSTORE
import Sparkle
#endif
import SwiftUI

@main
struct ArgosApp: App {
    @AppStorage("appearance") private var appearance = "system"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    #if !APPSTORE
    // Sparkle: controlador del actualizador (OTA). `startingUpdater: true` arranca los
    // chequeos programados en segundo plano (gobernados por SUEnableAutomaticChecks).
    // En el canal App Store no existe: las actualizaciones las entrega la App Store.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
                .tint(ArgosTheme.controlAccent)
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            // Menú «Pestañas»: ⌘T nueva ventana/conversación, ⌘W cerrar, ⌘1…⌘9,
            // ⌘⇧[ ⌘⇧] y ⌘⌥1…3 para lanzar agentes. También quita "Nueva ventana" (⌘N)
            // por defecto: la app es de una sola ventana (cada ventana crearía su propio
            // ServerStore aislado, confuso) y ⌘N es "Nuevo proyecto".
            TabCommands()

            // Menú de la app: "Acerca de Argos" propio (panel nativo con icono/enlaces)
            // + "Buscar actualizaciones…" (Sparkle, o la ficha de la App Store).
            CommandGroup(replacing: .appInfo) {
                Button("Acerca de Argos") { AboutPanel.show() }
                #if APPSTORE
                Button("Buscar actualizaciones…") { Self.open(AppStoreLinks.productPage) }
                #else
                CheckForUpdatesView(updater: updaterController.updater)
                #endif
            }

            // Menú Ayuda funcional (reemplaza el "ayuda no disponible" por defecto).
            CommandGroup(replacing: .help) {
                Button("Documentación de Argos") { Self.open(AboutPanel.repoURL) }
                Button("Novedades…") {
                    Self.open(URL(string: "https://github.com/victalejo/Argos/releases")!)
                }
                Divider()
                Button("Reportar un problema…") {
                    Self.open(URL(string: "https://github.com/victalejo/Argos/issues/new")!)
                }
            }

            // Cambiador rápido de sesión (⌘K) y zoom de fuente del terminal, en el
            // menú Visualización.
            CommandGroup(after: .sidebar) {
                Button("Cambiar de sesión…") { QuickSwitcher.shared.present() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Aumentar tamaño de fuente") { TerminalSettings.shared.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Reducir tamaño de fuente") { TerminalSettings.shared.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Tamaño de fuente original") { TerminalSettings.shared.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
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
            #if APPSTORE
            SettingsView()
                .preferredColorScheme(colorScheme)
            #else
            SettingsView(updater: updaterController.updater)
                .preferredColorScheme(colorScheme)
            #endif
        }
    }

    /// Abre una URL en el navegador por defecto (para los ítems del menú Ayuda).
    private static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
