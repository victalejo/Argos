//
//  ArgosShortcuts.swift
//  ArgosiOS
//
//  Atajos que aparecen solos en la app Atajos, Siri y Spotlight (sin que el usuario los
//  cree). Cada frase debe nombrar la app; las que llevan el proyecto se rellenan con la
//  caché de proyectos (`ProjectShortcutIndex` avisa al sistema cuando cambia).
//

import AppIntents

struct ArgosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskClaudeIntent(),
            phrases: [
                "Pedir a Claude en \(\.$project) con \(.applicationName)",
                "Encargar a Claude en \(\.$project) con \(.applicationName)",
                "Pedir a Claude con \(.applicationName)",
            ],
            shortTitle: "Pedir a Claude",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenProjectIntent(),
            phrases: [
                "Abrir \(\.$project) en \(.applicationName)",
                "Abrir un proyecto de \(.applicationName)",
            ],
            shortTitle: "Abrir proyecto",
            systemImageName: "folder"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .purple }
}
