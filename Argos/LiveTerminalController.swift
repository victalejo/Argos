//
//  LiveTerminalController.swift
//  Argos
//
//  Fase 2: une el `TerminalView` de SwiftTerm con un PTY remoto (vía SSHService),
//  haciendo de `TerminalViewDelegate` y gestionando el ciclo de vida (start/stop).
//
//  Flujo bidireccional:
//   - PTY  -> TerminalView : SSHService entrega bytes por un AsyncStream que el
//     `feeder` (en MainActor) inyecta con `terminalView.feed(byteArray:)`.
//   - TerminalView -> PTY  : el delegate `send(source:data:)` encola las teclas y
//     `sizeChanged(source:newCols:newRows:)` encola el resize (window-change).
//
//  Símbolos reales de SwiftTerm usados:
//   - TerminalView (NSView de AppKit, Mac/MacTerminalView.swift)
//   - terminalView.terminalDelegate / getTerminal().cols/rows
//   - feed(byteArray: ArraySlice<UInt8>)
//   - TerminalViewDelegate.send(source:data:) / .sizeChanged(source:newCols:newRows:)
//

import Foundation
import AppKit          // NSPasteboard
import Observation
import SwiftTerm

/// Estado observable de la conexión del terminal en vivo.
enum LiveTerminalStatus: Sendable, Equatable {
    case connecting
    case connected
    case ended
    case failed(String)
}

/// Controla un terminal en vivo adjuntado a una sesión tmux concreta.
///
/// Vive en el `MainActor`: posee el `TerminalView` (UI) y actúa como su delegate.
@MainActor
@Observable
final class LiveTerminalController: TerminalViewDelegate {

    /// La NSView de SwiftTerm que se incrusta en SwiftUI mediante un NSViewRepresentable.
    let terminalView: TerminalView

    /// Estado de la conexión (para feedback en la UI).
    private(set) var status: LiveTerminalStatus = .connecting

    private let service: SSHService
    private let sessionName: String

    private var task: Task<Void, Never>?
    private var isStopping = false

    // Stream de control (teclas / resize). Se crea en `init` como `let` Sendable para
    // que los métodos `nonisolated` del delegate puedan encolar directamente, sin saltar
    // de actor: así las pulsaciones conservan su orden y no se introduce latencia.
    private let controlStream: AsyncStream<TerminalControlEvent>
    private let controlContinuation: AsyncStream<TerminalControlEvent>.Continuation

    init(service: SSHService, sessionName: String) {
        self.service = service
        self.sessionName = sessionName
        let (controlStream, controlContinuation) = AsyncStream<TerminalControlEvent>.makeStream()
        self.controlStream = controlStream
        self.controlContinuation = controlContinuation
        self.terminalView = TerminalView(frame: .zero)
        self.terminalView.terminalDelegate = self
        start()
    }

    // El detach/limpieza lo dispara `stop()`, invocado de forma fiable por el `defer`
    // de la `.task(id:)` del detalle al cambiar de sesión o cerrarse la vista.

    // MARK: - Ciclo de vida

    /// Abre el PTY y conecta los flujos. Idempotente: no relanza si ya hay una tarea.
    private func start() {
        guard task == nil else { return }

        let (outputStream, outputCont) = AsyncStream<[UInt8]>.makeStream()

        // Tamaño inicial del PTY tomado del terminal (se corrige con el primer resize).
        let terminal = terminalView.getTerminal()
        let initialCols = terminal.cols
        let initialRows = terminal.rows

        let service = self.service
        let name = self.sessionName
        let controlStream = self.controlStream

        task = Task { [weak self] in
            // Feeder (MainActor): consume la salida del PTY y la pinta en el TerminalView.
            let feeder = Task { @MainActor [weak self] in
                for await bytes in outputStream {
                    guard let self else { continue }
                    if self.status == .connecting { self.status = .connected }
                    self.terminalView.feed(byteArray: bytes[...])
                }
            }

            do {
                try await service.attachTerminal(
                    session: name,
                    initialCols: initialCols,
                    initialRows: initialRows,
                    control: controlStream,
                    output: outputCont
                )
                self?.finish(error: nil)
            } catch is CancellationError {
                // Parada normal (cambio de sesión / cierre del detail): no es un error.
            } catch {
                self?.finish(error: error)
            }

            feeder.cancel()
        }
    }

    /// Detach + limpieza. Cancela la tarea (cierra el canal -> tmux desengancha este
    /// cliente, la sesión sobrevive) y cierra los streams. NO mata la sesión tmux.
    func stop() {
        isStopping = true
        controlContinuation.finish() // idempotente; tras esto, los `yield` son no-ops.
        task?.cancel()
        task = nil
    }

    private func finish(error: Error?) {
        guard !isStopping else { return }
        if let error {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
        } else {
            status = .ended
        }
    }

    // MARK: - TerminalViewDelegate
    //
    // SwiftTerm invoca estos métodos desde el hilo principal. Los marcamos `nonisolated`
    // para satisfacer el protocolo (no aislado) sin warnings de data race: solo tocan la
    // continuación (Sendable, thread-safe) o APIs de AppKit no aisladas.

    /// El usuario tecleó: enviamos esos bytes al stdin del PTY.
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        controlContinuation.yield(.input(Array(data)))
    }

    /// El TerminalView cambió de tamaño: propagamos columnas/filas al PTY (window-change).
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        controlContinuation.yield(.resize(cols: newCols, rows: newRows))
    }

    /// OSC 52: la app remota pidió copiar al portapapeles.
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Métodos restantes del protocolo sin comportamiento específico para este caso.
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
