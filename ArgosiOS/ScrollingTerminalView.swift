//
//  ScrollingTerminalView.swift
//  ArgosiOS
//
//  `TerminalView` de SwiftTerm que desplaza con el dedo aunque la app remota tenga el
//  ratón activo. Con tmux en `mouse on`, SwiftTerm convierte el arrastre en un arrastre
//  de ratón (tmux selecciona texto) y no había forma de subir por el historial. Aquí el
//  arrastre vertical se envía como rueda (botones 4/5), igual que la rueda en el Mac.
//  Tocar sigue llegando como clic, y la pulsación larga sigue seleccionando.
//

import SwiftTerm
import UIKit

final class ScrollingTerminalView: TerminalView, UIGestureRecognizerDelegate {

    private var wheel = TerminalWheelAccumulator()
    private lazy var wheelPan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleWheelPan))
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = self
        return gesture
    }()

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
        addGestureRecognizer(wheelPan)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(wheelPan)
    }

    /// No se llama a `super`: así SwiftTerm no instala su gesto de arrastre de ratón
    /// (que en tmux seleccionaría en lugar de desplazar).
    override func mouseModeChanged(source: Terminal) {}

    private var mouseReportingActive: Bool {
        allowMouseReporting && getTerminal().mouseMode != .off
    }

    @objc private func handleWheelPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            wheel.reset()
        case .changed:
            let terminal = getTerminal()
            guard terminal.rows > 0, bounds.height > 0 else { return }
            let deltaY = Double(gesture.translation(in: self).y)
            gesture.setTranslation(.zero, in: self)
            let rowHeight = Double(bounds.height) / Double(terminal.rows)
            guard let result = wheel.add(deltaY: deltaY, stepHeight: rowHeight) else { return }
            let button = result.direction == .up ? 4 : 5
            let flags = terminal.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
            let (col, row) = gridPosition(of: gesture.location(in: self), cols: terminal.cols, rows: terminal.rows)
            for _ in 0..<result.steps {
                terminal.sendEvent(buttonFlags: flags, x: col, y: row)
            }
        default:
            wheel.reset()
        }
    }

    /// Celda bajo el dedo (tmux desplaza el panel que hay debajo).
    private func gridPosition(of point: CGPoint, cols: Int, rows: Int) -> (Int, Int) {
        guard cols > 0, rows > 0, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let col = Int(point.x / (bounds.width / CGFloat(cols)))
        let row = Int((point.y - contentOffset.y) / (bounds.height / CGFloat(rows)))
        return (min(max(0, col), cols - 1), min(max(0, row), rows - 1))
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Solo con el ratón activo (tmux) y si el arrastre es más vertical que horizontal; si
    /// no, se deja el scroll local de SwiftTerm.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === wheelPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard mouseReportingActive else { return false }
        let velocity = wheelPan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }
}
