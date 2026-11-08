//
//  TerminalMouseSelection.swift
//  Argos
//
//  Selección de texto nativa en el terminal aunque tmux tenga `mouse on`.
//

import AppKit
import SwiftTerm

/// Permite seleccionar y copiar (Cmd+C) arrastrando sobre el terminal cuando la app
/// remota tiene el mouse reporting activo (tmux con `set -g mouse on`).
///
/// Sin esto, SwiftTerm reenvía TODOS los clics y arrastres al PTY y nunca hace su
/// selección local. Reglas:
/// - **Arrastrar** o **doble/triple clic** → selección local del Mac.
/// - **Clic simple** (sin arrastre) → se reenvía al PTY (tmux sigue recibiendo los clics
///   para cambiar de panel/ventana).
/// - **Option + arrastrar** → se reenvía tal cual al PTY (copy-mode de tmux, que puede
///   seleccionar más allá de lo visible).
///
/// `mouseDown`/`mouseUp` de `TerminalView` son `public` (no `open`) y no se pueden
/// sobreescribir, así que se usa un monitor local de eventos que conmuta
/// `allowMouseReporting` antes de que AppKit entregue cada evento a la vista.
@MainActor
final class TerminalMouseSelection {
    private weak var terminalView: TerminalView?
    private var monitor: Any?
    /// Pulsación simple aún sin decidir: si no hay arrastre, se reenvía al PTY al soltar.
    private var pendingDown: NSEvent?
    /// Hay un gesto local en curso (selección del Mac) con el reporting desactivado.
    private var localGesture = false

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
    }

    func install() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        // Los monitores LOCALES se entregan en el hilo principal (ver installScrollMonitor).
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown: return handleDown(event)
        case .leftMouseDragged: return handleDragged(event)
        case .leftMouseUp: return handleUp(event)
        default: return event
        }
    }

    private func handleDown(_ event: NSEvent) -> NSEvent? {
        reset()
        guard let view = terminalView, targetsTerminal(event, view: view),
              reportingActive(view), !event.modifierFlags.contains(.option)
        else { return event }

        // Reporting desactivado: SwiftTerm limpia la selección previa (clic simple) o
        // selecciona palabra/línea (doble/triple clic) en local.
        view.allowMouseReporting = false
        localGesture = true
        if event.clickCount == 1 { pendingDown = event }
        return event
    }

    private func handleDragged(_ event: NSEvent) -> NSEvent? {
        // Al arrastrar, la pulsación deja de ser un clic para el PTY: selección local.
        if localGesture { pendingDown = nil }
        return event
    }

    private func handleUp(_ event: NSEvent) -> NSEvent? {
        guard localGesture, let view = terminalView else { return event }
        if let down = pendingDown {
            // Clic simple sin arrastre: lo recibe la app remota (press + release).
            view.allowMouseReporting = true
            view.mouseDown(with: down)
            reset()
            return event
        }
        // Fin de la selección local: se entrega el mouseUp sin reporting y luego se
        // restaura para que la rueda y los clics sigan llegando a tmux.
        localGesture = false
        DispatchQueue.main.async { [weak view] in view?.allowMouseReporting = true }
        return event
    }

    private func reset() {
        pendingDown = nil
        if localGesture { terminalView?.allowMouseReporting = true }
        localGesture = false
    }

    private func targetsTerminal(_ event: NSEvent, view: TerminalView) -> Bool {
        guard let window = view.window, event.window === window,
              let contentView = window.contentView
        else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(point) === view
    }

    private func reportingActive(_ view: TerminalView) -> Bool {
        if case .off = view.getTerminal().mouseMode { return false }
        return true
    }
}
