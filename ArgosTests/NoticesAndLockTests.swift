//
//  NoticesAndLockTests.swift
//  ArgosTests
//
//  Estado de los avisos en iPhone/iPad, supresión por ventana y bloqueo con Face ID.
//

import Foundation
import Testing
@testable import Argos

@Suite("Estado de los avisos")
struct NotificationReadinessTests {

    @Test("Todo en orden: sin problemas")
    func ready() {
        let state = NotificationReadiness(permission: .authorized, backgroundRefresh: .available, lowPowerMode: false)
        #expect(state.isReady)
        #expect(state.issues.isEmpty)
        #expect(state.summary.contains("cuando iOS lo permite"))
    }

    @Test("Sin pedir el permiso: se puede pedir desde la app")
    func notRequested() {
        let state = NotificationReadiness(permission: .notDetermined, backgroundRefresh: .available, lowPowerMode: false)
        #expect(state.issues == [.permissionNotRequested])
        #expect(!NotificationReadiness.Issue.permissionNotRequested.needsSettings)
        #expect(state.summary == "Los avisos no pueden llegar.")
    }

    @Test("Denegado y alertas apagadas llevan a Ajustes y bloquean todo")
    func denied() {
        let denied = NotificationReadiness(permission: .denied, backgroundRefresh: .denied, lowPowerMode: true)
        #expect(denied.issues == [.permissionDenied, .backgroundRefreshOff])
        #expect(denied.issues.allSatisfy { $0.needsSettings })
        let alertsOff = NotificationReadiness(permission: .authorized, alertsEnabled: false, backgroundRefresh: .available, lowPowerMode: false)
        #expect(alertsOff.issues == [.alertsOff])
        #expect(NotificationReadiness.Issue.alertsOff.blocksAllNotices)
    }

    @Test("Sin segundo plano o con bajo consumo, solo llegan con la app abierta")
    func backgroundLimited() {
        let lowPower = NotificationReadiness(permission: .authorized, backgroundRefresh: .available, lowPowerMode: true)
        #expect(lowPower.issues == [.lowPowerMode])
        #expect(!NotificationReadiness.Issue.lowPowerMode.needsSettings)
        #expect(lowPower.summary == "Solo llegan con Argos abierto.")
        let restricted = NotificationReadiness(permission: .quiet, backgroundRefresh: .restricted, lowPowerMode: true)
        // El bajo consumo no se menciona si el segundo plano ya está bloqueado.
        #expect(restricted.issues == [.backgroundRefreshRestricted])
        #expect(!NotificationReadiness.Issue.backgroundRefreshRestricted.blocksAllNotices)
    }

    @Test("Provisional: llegan sin sonido")
    func quiet() {
        let state = NotificationReadiness(permission: .quiet, backgroundRefresh: .available, lowPowerMode: false)
        #expect(state.isReady)
        #expect(state.summary.contains("sin sonido"))
    }

    @Test("Cada problema tiene título y explicación")
    func texts() {
        let all: [NotificationReadiness.Issue] = [
            .permissionNotRequested, .permissionDenied, .alertsOff,
            .backgroundRefreshOff, .backgroundRefreshRestricted, .lowPowerMode,
        ]
        #expect(Set(all.map { $0.id }).count == all.count)
        #expect(all.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }
}

@Suite("Supresión de avisos de Claude por ventana")
struct ClaudeNoticeSuppressionTests {
    private let server = UUID()

    private func transition(_ session: String, _ window: Int) -> ClaudeTransition {
        ClaudeTransition(session: session, window: window, activity: .waiting)
    }

    @Test("Solo se calla la ventana que está a la vista en el terminal")
    func perWindow() {
        let focus = TerminalFocus(serverID: server, session: "api", window: 1)
        let all = [transition("api", 1), transition("api", 2), transition("web", 1)]
        let kept = ClaudeNoticeSuppression.notices(all, serverID: server, focus: focus)
        #expect(kept == [transition("api", 2), transition("web", 1)])
    }

    @Test("Sin terminal a la vista (Archivos, lista…) se avisa de todo")
    func noFocus() {
        let all = [transition("api", 1)]
        #expect(ClaudeNoticeSuppression.notices(all, serverID: server, focus: nil) == all)
        // El foco es de otro servidor.
        let other = TerminalFocus(serverID: UUID(), session: "api", window: 1)
        #expect(ClaudeNoticeSuppression.notices(all, serverID: server, focus: other) == all)
    }

    @Test("Sin conocer aún la ventana activa se calla la sesión")
    func unknownWindow() {
        let focus = TerminalFocus(serverID: server, session: "api", window: nil)
        #expect(ClaudeNoticeSuppression.notices([transition("api", 3)], serverID: server, focus: focus).isEmpty)
    }
}

@Suite("Bloqueo con Face ID")
struct AppLockPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Desactivado nunca bloquea ni tapa")
    func disabled() {
        #expect(!AppLockPolicy.shouldLock(enabled: false, backgroundedAt: nil, now: now))
        #expect(!AppLockPolicy.shouldCover(enabled: false, isLocked: true, isActive: false))
    }

    @Test("Bloquea al arrancar y tras el margen en segundo plano")
    func lockTiming() {
        #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: nil, now: now))
        #expect(!AppLockPolicy.shouldLock(enabled: true, backgroundedAt: now.addingTimeInterval(-10), now: now))
        #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: now.addingTimeInterval(-AppLockPolicy.gracePeriod), now: now))
        // Reloj hacia atrás.
        #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: now.addingTimeInterval(30), now: now))
    }

    @Test("Tapa el contenido fuera de primer plano o bloqueado")
    func cover() {
        #expect(AppLockPolicy.shouldCover(enabled: true, isLocked: false, isActive: false))
        #expect(AppLockPolicy.shouldCover(enabled: true, isLocked: true, isActive: true))
        #expect(!AppLockPolicy.shouldCover(enabled: true, isLocked: false, isActive: true))
    }
}
