//
//  TabCommands.swift
//  Argos
//
//  Atajos de pestañas (⌘T, ⌘W, ⌘1…⌘9, ⌘⇧[ / ⌘⇧], ⌘⌥1…3) en la barra de menús. La
//  vista activa del detalle (terminal o agente) publica sus acciones con
//  `focusedSceneValue(\.tabActions, …)`, así cada atajo hace lo que toca en cada modo:
//  en el terminal abre/cierra ventanas tmux y en el agente, conversaciones.
//

import AppKit
import SwiftUI

/// Acciones de pestaña que expone la vista activa del detalle.
///
/// Es `Equatable` por `identity` (los closures no se comparan): sin esto, cada
/// redibujado del terminal publicaría un valor «nuevo» y SwiftUI reconstruiría la
/// barra de menús sin parar (el menú parpadeaba). `identity` debe cambiar siempre que
/// cambie lo que capturan los closures (pestañas, activa, agentes instalados…).
struct TabActions: Equatable {
    var identity: AnyHashable
    /// Textos de los ítems («Nueva ventana» / «Nueva conversación»…).
    var newTitle: String
    var closeTitle: String
    var newTab: () -> Void
    var closeTab: () -> Void
    /// Salta a la pestaña ⌘N (1…9; 9 = la última).
    var selectTab: (Int) -> Void
    /// Pestaña anterior (−1) o siguiente (+1).
    var selectAdjacent: (Int) -> Void
    /// Lanzar un agente en una ventana nueva (solo en el terminal).
    var newAgent: ((CodingAgent) -> Void)?
    /// Agentes instalados en el servidor; `nil` mientras no se sabe.
    var installedAgents: Set<CodingAgent>?

    static func == (lhs: TabActions, rhs: TabActions) -> Bool {
        lhs.identity == rhs.identity
    }
}

extension FocusedValues {
    @Entry var tabActions: TabActions?
}

struct TabCommands: Commands {
    @FocusedValue(\.tabActions) private var actions

    var body: some Commands {
        // Sin «Nueva ventana» (⌘N) por defecto: la app es de una sola ventana.
        CommandGroup(replacing: .newItem) {}
        // Quita el «Cerrar» (⌘W) del sistema allí donde exista; lo sustituye el de
        // «Pestañas», que cierra la pestaña o, sin pestañas, la ventana clave.
        CommandGroup(replacing: .saveItem) {}

        // Menú propio (en macOS reciente no hay menú Archivo y los grupos de colocación
        // estándar no siempre aparecen). Va antes de «Ventana», así su ⌘W gana.
        CommandMenu("Pestañas") {
            Button(actions?.newTitle ?? "Nueva ventana") { actions?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions == nil)
            Menu("Iniciar un agente") {
                ForEach(CodingAgent.allCases) { agent in
                    Button(agentTitle(agent)) { actions?.newAgent?(agent) }
                        .keyboardShortcut(KeyEquivalent(agent.menuKey), modifiers: [.command, .option])
                        .disabled(!canLaunch(agent))
                }
            }
            .disabled(actions?.newAgent == nil)
            Button(actions?.closeTitle ?? "Cerrar") {
                if let actions {
                    actions.closeTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("Pestaña anterior") { actions?.selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Pestaña siguiente") { actions?.selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Última pestaña" : "Pestaña \(number)") { actions?.selectTab(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(actions == nil)
            }
        }
    }

    private func canLaunch(_ agent: CodingAgent) -> Bool {
        guard actions?.newAgent != nil else { return false }
        return actions?.installedAgents?.contains(agent) ?? true
    }

    private func agentTitle(_ agent: CodingAgent) -> String {
        guard let installed = actions?.installedAgents, !installed.contains(agent) else {
            return agent.displayName
        }
        return "\(agent.displayName) (no instalado)"
    }
}
