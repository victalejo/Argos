//
//  TerminalWheelAccumulatorTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("Arrastre del dedo → rueda del terminal")
struct TerminalWheelAccumulatorTests {

    @Test func unaFilaPorCadaAlturaDeFilaYConservaElResto() {
        var wheel = TerminalWheelAccumulator()
        #expect(wheel.add(deltaY: 10, stepHeight: 16) == nil)
        let first = wheel.add(deltaY: 10, stepHeight: 16)
        #expect(first?.direction == .up)
        #expect(first?.steps == 1)
        #expect(wheel.pending == 4)
    }

    @Test func elDedoHaciaArribaBajaHaciaLoReciente() {
        var wheel = TerminalWheelAccumulator()
        let result = wheel.add(deltaY: -50, stepHeight: 16)
        #expect(result?.direction == .down)
        #expect(result?.steps == 3)
    }

    @Test func limitaLasRafagasYAceptaValoresRaros() {
        var wheel = TerminalWheelAccumulator()
        #expect(wheel.add(deltaY: 10_000, stepHeight: 16)?.steps == TerminalWheelAccumulator.maxStepsPerUpdate)
        wheel.reset()
        #expect(wheel.add(deltaY: 40, stepHeight: 0) == nil)
        #expect(wheel.add(deltaY: .nan, stepHeight: 16) == nil)
        #expect(wheel.pending == 0)
    }
}
