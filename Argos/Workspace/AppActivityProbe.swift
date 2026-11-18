//
//  AppActivityProbe.swift
//  Argos
//
//  Qué hace la app ahora mismo, para el ritmo del sondeador y para no avisar de la sesión
//  que se está mirando: delante, detrás, tapada/minimizada/oculta, sin ventana o con el
//  Mac dormido. Se mira en el momento (es barato y no necesita observar notificaciones).
//

import AppKit

@MainActor
enum AppActivityProbe {
    static func current() -> WorkspaceActivity {
        if SystemSleepMonitor.shared.isAsleep { return .asleep }
        // Oculta con ⌘H: sus ventanas no están visibles, pero siguen abiertas.
        if NSApp.isHidden { return .hidden }
        let windows = mainWindows
        if windows.isEmpty { return .windowClosed }
        if !windows.contains(where: isOnScreen) { return .hidden }
        return NSApp.isActive ? .active : .inactive
    }

    /// La ventana principal está abierta (aunque esté minimizada o tapada).
    static var hasMainWindow: Bool { !mainWindows.isEmpty }

    /// La ventana de trabajo abierta (no paneles, la de la barra de menús ni Ajustes).
    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { window in
            guard window.canBecomeMain, !(window is NSPanel), !isSettings(window) else { return false }
            return window.isVisible || window.isMiniaturized
        }
    }

    private static func isSettings(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("settings")
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
}
