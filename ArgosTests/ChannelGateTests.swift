//
//  ChannelGateTests.swift
//  ArgosTests
//
//  El tope de canales de la conexión compartida: nunca más de `limit` a la vez, los
//  que esperan entran en orden al liberarse un cupo, el usuario va por delante del
//  fondo, la espera es cancelable y el tope baja si el servidor rechaza un canal.
//

import Foundation
import Testing
@testable import Argos

@Suite("Tope de canales SSH")
struct ChannelGateTests {

    @Test("Entra sin esperar mientras hay cupo")
    func admitsUpToLimit() async throws {
        let gate = ChannelGate(limit: 2)
        try await gate.acquire()
        try await gate.acquire()
        #expect(await gate.activeCount == 2)
        await gate.release()
        await gate.release()
        #expect(await gate.activeCount == 0)
    }

    @Test("Con el cupo lleno espera y entra al liberarse uno")
    func waitsWhenFull() async throws {
        let gate = ChannelGate(limit: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire(); return true }
        while await gate.waitingCount == 0 { await Task.yield() }
        #expect(await gate.activeCount == 1)
        await gate.release()
        #expect(try await waiter.value)
        #expect(await gate.activeCount == 1)
        await gate.release()
        #expect(await gate.activeCount == 0)
    }

    @Test("Muchas tareas a la vez nunca superan el límite")
    func neverExceedsLimit() async {
        let gate = ChannelGate(limit: 3)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                let priority: ConnectionPriority = index.isMultiple(of: 2) ? .user : .background
                group.addTask {
                    guard (try? await gate.acquire(priority)) != nil else { return }
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(2))
                    await peak.leave()
                    await gate.release(priority)
                }
            }
        }
        #expect(await peak.max <= 3)
        #expect(await gate.activeCount == 0)
    }

    @Test("Un límite inválido se trata como 1")
    func clampsLimit() {
        #expect(ChannelGate(limit: 0).limit == 1)
    }

    @Test("La espera entre reintentos crece")
    func retryDelayGrows() {
        #expect(ChannelRetry.delay(forAttempt: 1) < ChannelRetry.delay(forAttempt: 2))
    }

    // MARK: - Clases de turno

    @Test("El fondo no ocupa más de la mitad del cupo")
    func backgroundIsCapped() async throws {
        let gate = ChannelGate(limit: 6)
        #expect(await gate.backgroundLimit == 3)
        for _ in 0..<3 { try await gate.acquire(.background) }
        let fourth = Task { try await gate.acquire(.background) }
        while await gate.waitingCount == 0 { await Task.yield() }
        #expect(await gate.activeCount == 3)
        // El usuario sí entra aunque el fondo espere.
        try await gate.acquire(.user)
        #expect(await gate.activeCount(.user) == 1)
        await gate.release(.background)
        try await fourth.value
        #expect(await gate.activeCount(.background) == 3)
    }

    @Test("Al liberarse un turno, el usuario pasa por delante del fondo que esperaba antes")
    func userGoesFirst() async throws {
        let gate = ChannelGate(limit: 2)
        try await gate.acquire(.user)
        try await gate.acquire(.user)
        let order = Order()
        let background = Task { try await gate.acquire(.background); await order.append("fondo") }
        while await gate.waitingCount < 1 { await Task.yield() }
        let user = Task { try await gate.acquire(.user); await order.append("usuario") }
        while await gate.waitingCount < 2 { await Task.yield() }

        await gate.release(.user)
        try await user.value
        #expect(await order.items == ["usuario"])
        await gate.release(.user)
        try await background.value
        #expect(await order.items == ["usuario", "fondo"])
    }

    // MARK: - Cancelación

    @Test("Cancelar mientras espera saca de la cola sin ocupar turno")
    func cancellationLeavesQueue() async throws {
        let gate = ChannelGate(limit: 1)
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        while await gate.waitingCount == 0 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await gate.waitingCount == 0)
        #expect(await gate.activeCount == 1)
        await gate.release()
        #expect(await gate.activeCount == 0)
    }

    @Test("Una tarea ya cancelada no entra aunque haya cupo")
    func alreadyCancelledDoesNotEnter() async {
        let gate = ChannelGate(limit: 3)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.activeCount == 0)
    }

    // MARK: - Límite adaptativo

    @Test("Un rechazo del servidor baja el tope y se recuerda hasta reiniciarlo")
    func lowersLimitAfterRejection() async throws {
        let gate = ChannelGate(limit: 6)
        for _ in 0..<5 { try await gate.acquire() }
        #expect(await gate.lowerLimitAfterRejection() == 4)
        #expect(await gate.currentLimit == 4)
        #expect(await gate.backgroundLimit == 2)
        for _ in 0..<5 { await gate.release() }

        // Con el tope bajado, el quinto espera.
        for _ in 0..<4 { try await gate.acquire() }
        let fifth = Task { try await gate.acquire() }
        while await gate.waitingCount == 0 { await Task.yield() }

        // Conexión nueva: vuelve al tope de partida y entra el que esperaba.
        await gate.resetLimit()
        try await fifth.value
        #expect(await gate.currentLimit == 6)
        #expect(await gate.activeCount == 5)
    }

    @Test("El tope adaptativo nunca baja de 2")
    func adaptiveFloor() async throws {
        let gate = ChannelGate(limit: 6)
        try await gate.acquire()
        #expect(await gate.lowerLimitAfterRejection() == 2)
        #expect(await gate.lowerLimitAfterRejection() == 2)
    }
}

private actor Peak {
    private var current = 0
    private(set) var max = 0
    func enter() { current += 1; max = Swift.max(max, current) }
    func leave() { current -= 1 }
}

private actor Order {
    private(set) var items: [String] = []
    func append(_ item: String) { items.append(item) }
}
