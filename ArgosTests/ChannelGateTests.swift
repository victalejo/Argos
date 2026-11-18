//
//  ChannelGateTests.swift
//  ArgosTests
//
//  El tope de canales de la conexión compartida: nunca más de `limit` a la vez y los
//  que esperan entran en orden al liberarse un cupo.
//

import Foundation
import Testing
@testable import Argos

@Suite("Tope de canales SSH")
struct ChannelGateTests {

    @Test("Entra sin esperar mientras hay cupo")
    func admitsUpToLimit() async {
        let gate = ChannelGate(limit: 2)
        await gate.acquire()
        await gate.acquire()
        #expect(await gate.activeCount == 2)
        await gate.release()
        await gate.release()
        #expect(await gate.activeCount == 0)
    }

    @Test("Con el cupo lleno espera y entra al liberarse uno")
    func waitsWhenFull() async {
        let gate = ChannelGate(limit: 1)
        await gate.acquire()
        let waiter = Task { await gate.acquire(); return true }
        while await gate.waitingCount == 0 { await Task.yield() }
        #expect(await gate.activeCount == 1)
        await gate.release()
        #expect(await waiter.value)
        #expect(await gate.activeCount == 1)
        await gate.release()
        #expect(await gate.activeCount == 0)
    }

    @Test("Muchas tareas a la vez nunca superan el límite")
    func neverExceedsLimit() async {
        let gate = ChannelGate(limit: 3)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    await gate.acquire()
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(2))
                    await peak.leave()
                    await gate.release()
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
}

private actor Peak {
    private var current = 0
    private(set) var max = 0
    func enter() { current += 1; max = Swift.max(max, current) }
    func leave() { current -= 1 }
}
