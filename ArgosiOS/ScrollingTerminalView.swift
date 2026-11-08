//
//  ScrollingTerminalView.swift
//  ArgosiOS
//
//  `TerminalView` de SwiftTerm que desplaza con el dedo aunque la app remota tenga el
//  ratón activo. Con tmux en `mouse on`, SwiftTerm convierte el arrastre en un arrastre
//  de ratón (tmux selecciona texto) y no había forma de subir por el historial. Aquí el
//  arrastre vertical se envía como rueda (botones 4/5), igual que la rueda en el Mac.
//
//  Seleccionar: mantener pulsado y arrastrar envía a tmux un arrastre con el botón
//  izquierdo; al soltar, tmux copia la selección y la reenvía por OSC 52, que llega al
//  portapapeles del iPhone (`TouchTerminalController.clipboardCopy`). Tocar sigue
//  llegando como clic.
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

    private lazy var selectPress: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleSelectPress))
        gesture.minimumPressDuration = 0.35
        gesture.delegate = self
        return gesture
    }()
    private let haptics = UISelectionFeedbackGenerator()

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
        installGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installGestures()
    }

    private func installGestures() {
        // El menú contextual de SwiftTerm (pulsación larga) solo actúa si la nuestra no
        // empieza, es decir, cuando la app remota no tiene el ratón activo.
        for gesture in gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer {
            gesture.require(toFail: selectPress)
        }
        addGestureRecognizer(selectPress)
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

    @objc private func handleSelectPress(_ gesture: UILongPressGestureRecognizer) {
        let terminal = getTerminal()
        let (col, row) = gridPosition(of: gesture.location(in: self), cols: terminal.cols, rows: terminal.rows)
        let press = terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)
        switch gesture.state {
        case .began:
            haptics.selectionChanged()
            terminal.sendEvent(buttonFlags: press, x: col, y: row)
        case .changed:
            terminal.sendMotion(buttonFlags: press, x: col, y: row, pixelX: col, pixelY: row)
        case .ended, .cancelled, .failed:
            let release = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
            terminal.sendEvent(buttonFlags: release, x: col, y: row)
        default:
            break
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

    /// Solo con el ratón activo (tmux). El arrastre, además, debe ser más vertical que
    /// horizontal; si no, se deja el comportamiento de SwiftTerm.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === selectPress { return mouseReportingActive }
        guard gestureRecognizer === wheelPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard mouseReportingActive else { return false }
        let velocity = wheelPan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }
}
