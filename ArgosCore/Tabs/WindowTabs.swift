//
//  WindowTabs.swift
//  Argos
//
//  Lógica pura de las pestañas de ventanas tmux: qué título mostrar, qué agente corre
//  en cada una, a qué ventana saltan los atajos (⌘1…⌘9, anterior/siguiente) y si
//  cerrar con ⌘W puede hacerse directamente o necesita confirmación.
//

import Foundation

/// Qué hacer cuando el usuario pide cerrar una ventana.
enum WindowCloseDecision: Equatable, Sendable {
    /// Es la última ventana: cerrarla mataría la sesión entera, así que no se hace.
    case blocked
    /// La ventana solo tiene un shell ocioso: se cierra sin preguntar.
    case immediate
    /// Hay algo corriendo (un agente, un servidor, varios paneles…): se confirma.
    case confirm
}

enum WindowTabs {
    /// Procesos que cuentan como «shell ocioso» (nada que perder al cerrar).
    static let shellCommands: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "ash", "nu",
    ]

    /// ¿`command` es un shell sin nada en primer plano? Tolera el guion inicial de los
    /// shells de login (`-zsh`).
    static func isIdleShell(_ command: String?) -> Bool {
        guard let command else { return false }
        let name = command.hasPrefix("-") ? String(command.dropFirst()) : command
        return shellCommands.contains(name.lowercased())
    }

    /// Decide cómo cerrar `window` sabiendo cuántas ventanas tiene la sesión.
    static func closeDecision(for window: TmuxWindow, totalWindows: Int) -> WindowCloseDecision {
        guard totalWindows > 1 else { return .blocked }
        if window.paneCount == 1 && isIdleShell(window.currentCommand) { return .immediate }
        return .confirm
    }

    /// Posición (0…count-1) para el atajo ⌘N (1…9). Como en los navegadores, ⌘9 salta
    /// siempre a la última. `nil` si no hay tantas pestañas.
    static func position(forShortcut number: Int, count: Int) -> Int? {
        guard (1...9).contains(number), count > 0 else { return nil }
        if number == 9 { return count - 1 }
        return number - 1 < count ? number - 1 : nil
    }

    /// Posición a `offset` de `current` (−1 anterior, +1 siguiente), dando la vuelta en
    /// los extremos. `nil` si hay menos de dos pestañas.
    static func adjacentPosition(current: Int, offset: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        return ((current + offset) % count + count) % count
    }

    /// Ventana para ⌘N (1…9; 9 = la última).
    static func window(atShortcut number: Int, in windows: [TmuxWindow]) -> TmuxWindow? {
        position(forShortcut: number, count: windows.count).map { windows[$0] }
    }

    /// Ventana anterior/siguiente a la activa, dando la vuelta en los extremos.
    static func adjacent(to windows: [TmuxWindow], offset: Int) -> TmuxWindow? {
        let current = windows.firstIndex { $0.isActive } ?? 0
        return adjacentPosition(current: current, offset: offset, count: windows.count).map { windows[$0] }
    }

    /// Agente de la ventana: por su proceso/nombre o, si los hooks de Claude lo
    /// informan, Claude Code.
    static func agent(for window: TmuxWindow, claudeReported: Bool) -> CodingAgent? {
        CodingAgent.detect(command: window.currentCommand, windowName: window.name)
            ?? (claudeReported ? .claude : nil)
    }

    /// Título de la pestaña: el nombre del agente, el nombre de la ventana o `nil`
    /// cuando el nombre es solo el del shell (la pestaña muestra entonces `>_ 1`).
    static func title(for window: TmuxWindow, agent: CodingAgent?) -> String? {
        if let agent { return agent.displayName }
        return isIdleShell(window.name) ? nil : window.name
    }

    /// Agentes que corren en más de una ventana: sus pestañas llevan también el número
    /// de ventana para distinguirlas («Claude Code 1», «Claude Code 2»).
    static func repeatedAgents(in windows: [TmuxWindow], claudeReported: Set<Int>) -> Set<CodingAgent> {
        var counts: [CodingAgent: Int] = [:]
        for window in windows {
            if let agent = agent(for: window, claudeReported: claudeReported.contains(window.index)) {
                counts[agent, default: 0] += 1
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }
}
