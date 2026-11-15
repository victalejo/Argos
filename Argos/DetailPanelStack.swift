//
//  DetailPanelStack.swift
//  Argos
//
//  3ª columna de un proyecto: mantiene VIVOS los paneles Archivos, Cambios y Agente ya
//  abiertos mientras se usa otro (ocultos, sin interacción ni atajos), para que al
//  volver sigan donde estaban: carpetas desplegadas, archivo abierto, scroll, diff…
//  Se reinicia al cambiar de proyecto (`.id(handle)` en quien lo usa).
//
//  El terminal no se conserva oculto: su estado ya vive en `TerminalSessionStore`, y
//  una vista de terminal invisible podría quedarse con el teclado.
//

import AppKit
import SwiftUI

extension EnvironmentValues {
    /// `false` mientras el panel está oculto detrás de otro (p. ej. para pausar sondeos).
    @Entry var isDetailPanelActive = true
}

struct DetailPanelStack<Panel: View>: View {
    let mode: DetailMode
    @ViewBuilder let panel: (DetailMode) -> Panel

    /// Paneles abiertos al menos una vez en este proyecto (salvo el terminal).
    @State private var opened: Set<DetailMode> = []

    private static var order: [DetailMode] { [.terminal, .files, .changes, .agent] }

    var body: some View {
        ZStack {
            ForEach(Self.order, id: \.self) { candidate in
                if candidate == mode || (candidate != .terminal && opened.contains(candidate)) {
                    let isActive = candidate == mode
                    panel(candidate)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .disabled(!isActive)  // sin atajos de teclado (⌘P, ⌘⏎…) mientras está oculto
                        .accessibilityHidden(!isActive)
                        .environment(\.isDetailPanelActive, isActive)
                        .zIndex(isActive ? 1 : 0)
                }
            }
        }
        .onAppear { remember(mode) }
        .onChange(of: mode) { _, newMode in
            remember(newMode)
            // Un campo de texto del panel que se oculta no debe seguir recibiendo el teclado.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func remember(_ mode: DetailMode) {
        if mode != .terminal { opened.insert(mode) }
    }
}
