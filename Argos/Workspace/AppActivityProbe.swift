//
//  AppActivityProbe.swift
//  Argos
//
//  Qué hace la app ahora mismo, para el ritmo del sondeador: delante, detrás, oculta
//  (sin ventana a la vista: minimizada, tapada o cerrada) o con el Mac dormido. Se mira
//  en el momento (es barato y no necesita observar notificaciones).
//

import AppKit

@MainActor
enum AppActivityProbe {
    static func current() -> WorkspaceActivity {
        if SystemSleepMonitor.shared.isAsleep { return .asleep }
        if NSApp.isHidden || !hasVisibleWindow { return .hidden }
        return NSApp.isActive ? .active : .inactive
    }

    /// Alguna ventana principal visible y no tapada del todo.
    private static var hasVisibleWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && window.occlusionState.contains(.visible)
        }
    }
}
