//
//  SystemSleepTests.swift
//  ArgosTests
//
//  Con el Mac dormido Argos no debe generar tráfico SSH proactivo (heartbeat, sondeo,
//  reconexión automática). Problema detectado por Kevin Jovy en la PR #2.
//

import AppKit
import Testing
@testable import Argos

@MainActor
@Suite("Reposo del Mac")
struct SystemSleepTests {

    @Test("willSleep / didWake cambian isAsleep")
    func monitorFollowsSleepNotifications() {
        let center = NotificationCenter()
        let monitor = SystemSleepMonitor(center: center)
        #expect(monitor.isAsleep == false)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(monitor.isAsleep == true)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(monitor.isAsleep == false)
    }

    @Test("Cambiar de app NO cuenta como reposo")
    func appDeactivationIsNotSleep() {
        let center = NotificationCenter()
        let monitor = SystemSleepMonitor(center: center)
        center.post(name: NSApplication.willResignActiveNotification, object: nil)
        #expect(monitor.isAsleep == false)
    }

    @Test("Dormir y despertar seguidos se aplican en orden a todos los servicios")
    func coordinatorKeepsOrder() async {
        let first = MockSSHService()
        let second = MockSSHService()
        let coordinator = HeartbeatSleepCoordinator()

        coordinator.apply(asleep: true, to: [first, second])
        coordinator.apply(asleep: false, to: [first, second])
        await coordinator.apply(asleep: true, to: [first, second]).value
        await coordinator.apply(asleep: false, to: [first, second]).value

        #expect(first.heartbeatSuspensions == [true, false, true, false])
        #expect(second.heartbeatSuspensions == [true, false, true, false])
    }

    @Test("Al despertar solo se reintenta un terminal caído por error")
    func reconnectOnWakeOnlyAfterFailure() {
        #expect(TerminalSleepPolicy.reconnectsOnWake(.failed("red")) == true)
        #expect(TerminalSleepPolicy.reconnectsOnWake(.connected) == false)
        #expect(TerminalSleepPolicy.reconnectsOnWake(.connecting) == false)
        #expect(TerminalSleepPolicy.reconnectsOnWake(.ended) == false)
        #expect(TerminalSleepPolicy.reconnectsOnWake(nil) == false)
    }
}
