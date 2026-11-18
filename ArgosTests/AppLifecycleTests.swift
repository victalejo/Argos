//
//  AppLifecycleTests.swift
//  ArgosTests
//
//  Vuelta de segundo plano en iPhone/iPad: sondeo de la conexión con plazo, paso real
//  por segundo plano, caducidad del destino de un aviso y planificación de la
//  comprobación en segundo plano.
//

import Foundation
import Testing
@testable import Argos

@Suite("Ciclo de vida de la app móvil")
struct AppLifecycleTests {

    /// Contador seguro entre tareas.
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    // MARK: - Deadline.value

    @Test("Deadline.value devuelve el resultado si llega a tiempo")
    func deadlineValueInTime() async {
        let value = await Deadline.value(within: .seconds(2)) { 42 }
        #expect(value == 42)
    }

    @Test("Deadline.value devuelve nil si vence el plazo, sin esperar a la operación")
    func deadlineValueTimesOut() async {
        let clock = ContinuousClock()
        let started = clock.now
        let value: Int? = await Deadline.value(within: .milliseconds(50)) {
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        #expect(value == nil)
        #expect(clock.now - started < .seconds(5))
    }

    // MARK: - ConnectionResume

    @Test("Conexión viva: no se desconecta")
    func resumeAlive() async {
        let disconnects = Counter()
        let outcome = await ConnectionResume.revalidate(
            timeout: .seconds(1), probe: { true }, disconnect: { await disconnects.increment() }
        )
        #expect(outcome == .alive)
        #expect(await disconnects.value == 0)
    }

    @Test("Conexión colgada: se descarta y la nueva responde")
    func resumeReconnects() async {
        let probes = Counter()
        let disconnects = Counter()
        let outcome = await ConnectionResume.revalidate(
            timeout: .milliseconds(100),
            probe: {
                await probes.increment()
                if await probes.value == 1 {
                    try? await Task.sleep(for: .seconds(30))   // la vieja no contesta
                }
                return true
            },
            disconnect: { await disconnects.increment() }
        )
        #expect(outcome == .reconnected)
        #expect(await disconnects.value == 1)
    }

    @Test("Ni la vieja ni una nueva responden: inalcanzable, y se desconecta otra vez")
    func resumeUnreachable() async {
        let disconnects = Counter()
        let outcome = await ConnectionResume.revalidate(
            timeout: .milliseconds(50), probe: { false }, disconnect: { await disconnects.increment() }
        )
        #expect(outcome == .unreachable)
        #expect(await disconnects.value == 2)
    }

    // MARK: - BackgroundTransitionTracker

    @Test("Solo cuenta el paso real por segundo plano, una vez")
    func backgroundTracker() {
        var tracker = BackgroundTransitionTracker()
        let fromInactive = tracker.becameActive()    // inactivo → activo (Centro de control)
        tracker.enteredBackground()
        let fromBackground = tracker.becameActive()
        let again = tracker.becameActive()
        #expect(!fromInactive)
        #expect(fromBackground)
        #expect(!again)
    }

    // MARK: - NotificationRouteExpiry

    @Test("El destino de un aviso no caduca mientras se conecta")
    func routeWaitsWhileConnecting() {
        #expect(!NotificationRouteExpiry.shouldExpire(elapsed: .seconds(90), sinceSettled: nil))
        #expect(!NotificationRouteExpiry.shouldExpire(elapsed: .seconds(90), sinceSettled: .seconds(10)))
        #expect(NotificationRouteExpiry.shouldExpire(elapsed: .seconds(90), sinceSettled: .seconds(30)))
        #expect(NotificationRouteExpiry.shouldExpire(elapsed: .seconds(180), sinceSettled: nil))
    }

    // MARK: - BackgroundCheckPlanner

    private func server(_ name: String) -> Server {
        Server(name: name, host: "\(name).example", username: "u", privateKeyPath: "/k")
    }

    @Test("Solo los servidores existentes y apuntados, con lo que toca revisar")
    func plannerItems() {
        let a = server("a"), b = server("b"), c = server("c")
        let items = BackgroundCheckPlanner.items(
            servers: [a, b, c],
            agentKeys: [a.id.uuidString, UUID().uuidString],
            claudeKeys: [a.id.uuidString, c.id.uuidString]
        )
        #expect(items == [
            .init(serverID: a.id, checkAgents: true, checkClaude: true),
            .init(serverID: c.id, checkAgents: false, checkClaude: true),
        ])
        #expect(BackgroundCheckPlanner.perServerTimeout <= .seconds(12))
    }

    // MARK: - CompletionOnce

    @MainActor
    @Test("La tarea del sistema se completa una sola vez")
    func completionOnce() {
        var calls: [Bool] = []
        let once = CompletionOnce { calls.append($0) }
        once.complete(success: false)
        once.complete(success: true)
        #expect(calls == [false])
        #expect(once.isCompleted)
    }
}
