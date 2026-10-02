//
//  AppSuspension.swift
//  Argos
//
//  Pausa el tráfico SSH proactivo cuando el Mac se va a dormir o la app deja de
//  estar en uso: el heartbeat (`SSHService`), el sondeo de ventanas
//  (`SessionTerminalView.pollWindows`) y la reconexión automática no deben abrir
//  conexiones nuevas mientras no haya nadie delante.
//
//  La lógica pura (`SuspensionPolicy`) está separada para poder testearla sin
//  notificaciones del sistema; `SuspensionMonitor` solo traduce notificaciones
//  de AppKit en ese booleano.
//

import AppKit
import Foundation
import Observation

extension Notification.Name {
    /// Se publica (hilo principal) cada vez que `SuspensionMonitor.isSuspended`
    /// cambia. `userInfo["suspended"]` trae el `Bool`.
    static let argosSuspensionChanged = Notification.Name("ArgosSuspensionChanged")
}

// MARK: - Política pura (testeable)

/// Decide si el tráfico SSH proactivo debe pausarse.
///
/// - `appActive`: `true` mientras Argos es la app activa.
/// - `systemAwake`: `false` entre `willSleep` y `didWake` del Mac.
enum SuspensionPolicy: Sendable {
    static func shouldSuspend(appActive: Bool, systemAwake: Bool) -> Bool {
        !appActive || !systemAwake
    }
}

// MARK: - Monitor (MainActor, observable por SwiftUI)

/// Observa el reposo del Mac y la actividad de la app y expone `isSuspended`.
///
/// - Reposo: `NSWorkspace.willSleepNotification` / `didWakeNotification` (se
///   publican en `NSWorkspace.shared.notificationCenter`, no en el default).
/// - Actividad: `NSApplication.willResignActiveNotification` /
///   `didBecomeActiveNotification` (van al `NotificationCenter.default`).
@MainActor
@Observable
final class SuspensionMonitor {
    /// Instancia compartida que usan las vistas.
    static let shared = SuspensionMonitor()

    /// `true` cuando hay que pausar el tráfico SSH proactivo.
    private(set) var isSuspended = false

    private var appActive = true {
        didSet { recompute() }
    }

    private var systemAwake = true {
        didSet { recompute() }
    }

    init() {
        startObserving()
    }

    /// Solo para tests: inyecta un estado sin notificaciones del sistema.
    func setForTesting(appActive: Bool, systemAwake: Bool) {
        self.appActive = appActive
        self.systemAwake = systemAwake
    }

    private func recompute() {
        let next = SuspensionPolicy.shouldSuspend(appActive: appActive, systemAwake: systemAwake)
        guard next != isSuspended else { return }
        isSuspended = next
        NotificationCenter.default.post(
            name: .argosSuspensionChanged,
            object: nil,
            userInfo: ["suspended": next]
        )
    }

    private func startObserving() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        defaultCenter.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        defaultCenter.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep() {
        systemAwake = false
    }

    @objc private func systemDidWake() {
        systemAwake = true
    }

    @objc private func appWillResignActive() {
        appActive = false
    }

    @objc private func appDidBecomeActive() {
        appActive = true
    }
}
