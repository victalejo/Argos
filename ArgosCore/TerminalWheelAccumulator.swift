//
//  TerminalWheelAccumulator.swift
//  ArgosCore
//
//  Convierte el arrastre vertical de un dedo en «clics» de rueda para el PTY. Con tmux
//  en `mouse on`, la rueda entra en copy-mode y desplaza el historial (p. ej. la salida
//  de Claude Code); un arrastre de ratón, en cambio, seleccionaría texto.
//
//  Lógica pura (sin UIKit) para poder probarla: acumula desplazamiento en puntos y
//  emite un paso por cada `stepHeight` recorrido, conservando el resto.
//

import Foundation

struct TerminalWheelAccumulator: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        /// Ver lo anterior (el dedo baja): rueda arriba.
        case up
        /// Ver lo más reciente (el dedo sube): rueda abajo.
        case down
    }

    /// Máximo de pasos por actualización del gesto (evita ráfagas al soltar rápido).
    static let maxStepsPerUpdate = 8

    private(set) var pending: Double = 0

    /// Añade `deltaY` puntos (positivo = el dedo baja) y devuelve los pasos a enviar.
    mutating func add(deltaY: Double, stepHeight: Double) -> (direction: Direction, steps: Int)? {
        guard stepHeight > 0, deltaY.isFinite else { return nil }
        pending += deltaY
        let whole = Int((pending / stepHeight).rounded(.towardZero))
        guard whole != 0 else { return nil }
        pending -= Double(whole) * stepHeight
        let steps = min(abs(whole), Self.maxStepsPerUpdate)
        return (whole > 0 ? .up : .down, steps)
    }

    mutating func reset() {
        pending = 0
    }
}
