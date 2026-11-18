//
//  TerminalWindowsModel.swift
//  ArgosCore
//
//  Ventanas y paneles de tmux de la sesión que se ve en el terminal: sondeo adaptativo de
//  sus ventanas (3 → 6 → 12 s sin cambios; vuelve a 3 s ante un cambio) y las acciones de
//  la barra de ventanas y del menú «Panel». Antes vivía en la vista y los fallos se
//  tragaban con `try?`; ahora se registran y quedan en `actionError` para el banner.
//

import Foundation
import Observation

@MainActor
@Observable
final class TerminalWindowsModel {
    let sessionName: String
    @ObservationIgnored private let service: any SSHServicing

    /// Ventanas de la sesión (barra superior).
    private(set) var windows: [TmuxWindow] = []
    /// Último fallo de una acción de ventana o panel; la interfaz lo muestra y lo borra.
    var actionError: String?

    nonisolated static let minInterval: Duration = .seconds(3)
    nonisolated static let maxInterval: Duration = .seconds(12)

    init(service: any SSHServicing, sessionName: String) {
        self.service = service
        self.sessionName = sessionName
    }

    var activeWindow: TmuxWindow? { windows.first { $0.isActive } }

    /// ¿La ventana activa tiene más de un panel? («Cerrar panel» no debe cerrar la ventana.)
    var activeWindowHasMultiplePanes: Bool { (activeWindow?.paneCount ?? 1) > 1 }

    /// Siguiente espera del sondeo (lógica pura): rápido tras un cambio, el doble si no.
    nonisolated static func nextInterval(after current: Duration, changed: Bool) -> Duration {
        changed ? minInterval : min(current * 2, maxInterval)
    }

    // MARK: - Sondeo

    /// Sondea mientras la tarea viva. `shouldPoll` decide en cada vuelta (conectado y el
    /// equipo despierto); si no, espera sin tocar la red.
    func poll(while shouldPoll: @MainActor () -> Bool, sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        var interval = Self.minInterval
        while !Task.isCancelled {
            if shouldPoll() {
                do {
                    let fresh = try await ConnectionPriority.background { try await service.listWindows(session: sessionName) }
                    let changed = fresh != windows
                    if changed { windows = fresh }
                    interval = Self.nextInterval(after: interval, changed: changed)
                } catch {
                    Log.terminal.debug("Sondeo de ventanas fallido: \(error.userMessage, privacy: .public)")
                }
            }
            do { try await sleep(interval) } catch { return }
        }
    }

    /// Relee las ventanas tras una acción (un fallo conserva las de antes).
    func refresh() async {
        do {
            windows = try await service.listWindows(session: sessionName)
        } catch {
            Log.terminal.notice("No se pudieron releer las ventanas: \(error.userMessage, privacy: .public)")
        }
    }

    /// Lista RECIÉN leída (para decidir un cierre); `nil` si falló (queda en `actionError`).
    func freshWindows() async -> [TmuxWindow]? {
        do {
            let fresh = try await service.listWindows(session: sessionName)
            windows = fresh
            return fresh
        } catch {
            report(error, while: String(localized: "leer las ventanas"))
            return nil
        }
    }

    // MARK: - Ventanas

    func select(_ window: TmuxWindow) async {
        await perform(String(localized: "cambiar de ventana")) { try await $0.selectWindow(session: $1, index: window.index) }
    }

    func newWindow() async {
        await perform(String(localized: "abrir una ventana")) { try await $0.newWindow(session: $1) }
    }

    func newAgentWindow(_ agent: CodingAgent, directory: String?) async {
        await perform(String(localized: "lanzar \(agent.displayName)")) {
            try await $0.newAgentWindow(session: $1, agent: agent, directory: directory)
        }
    }

    func setColor(_ color: WindowColor?, for window: TmuxWindow) async {
        await perform(String(localized: "cambiar el color de la ventana")) {
            try await $0.setWindowColor(session: $1, index: window.index, color: color)
        }
    }

    func close(_ window: TmuxWindow) async {
        await perform(String(localized: "cerrar la ventana")) { try await $0.killWindow(session: $1, index: window.index) }
    }

    // MARK: - Paneles

    func splitPane(vertical: Bool) async {
        await perform(String(localized: "dividir el panel")) { try await $0.splitPane(session: $1, vertical: vertical) }
    }

    func selectPane(_ direction: TmuxPaneDirection) async {
        await perform(String(localized: "cambiar de panel"), refreshing: false) { try await $0.selectPane(session: $1, direction: direction) }
    }

    func zoomPane() async {
        await perform(String(localized: "hacer zoom del panel"), refreshing: false) { try await $0.zoomPane(session: $1) }
    }

    func killPane() async {
        await perform(String(localized: "cerrar el panel")) { try await $0.killPane(session: $1) }
    }

    // MARK: - Utilidades

    private func perform(
        _ action: String,
        refreshing: Bool = true,
        _ operation: (any SSHServicing, String) async throws -> Void
    ) async {
        do {
            try await operation(service, sessionName)
        } catch {
            report(error, while: action)
        }
        if refreshing { await refresh() }
    }

    private func report(_ error: Error, while action: String) {
        Log.terminal.error("No se pudo \(action, privacy: .public): \(error.userMessage, privacy: .public)")
        actionError = String(localized: "No se pudo \(action): \(error.userMessage)")
    }
}
