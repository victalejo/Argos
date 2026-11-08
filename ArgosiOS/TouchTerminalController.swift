//
//  TouchTerminalController.swift
//  ArgosiOS
//
//  Versión iOS de `LiveTerminalController`: une el `TerminalView` de SwiftTerm (UIKit)
//  con el PTY remoto (`tmux attach` vía SSHService).
//
//  iOS suspende la app en segundo plano y el SSH muere; la sesión tmux sigue viva en
//  el servidor. Por eso el controlador se puede `reconnect()`ar al volver a primer
//  plano: reabre el PTY y tmux repinta la pantalla tal como estaba.
//

import Foundation
import Observation
import SwiftTerm
import UIKit

@MainActor
@Observable
final class TouchTerminalController: TerminalViewDelegate {

    let terminalView: TerminalView
    private(set) var status: LiveTerminalStatus = .connecting
    /// Aviso breve sobre el terminal («Copiado», «Subiendo…», un error).
    private(set) var notice: TerminalNotice?

    private let service: any SSHServicing
    private let sessionName: String

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Se incrementa en cada `start()`/`stop()`. Una tarea de PTY solo puede tocar el
    /// estado si su generación sigue siendo la actual: así una conexión vieja que
    /// termina tarde (tras `reconnect()`) no marca como caída a la nueva.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var controlStream: AsyncStream<TerminalControlEvent>
    @ObservationIgnored private var controlContinuation: AsyncStream<TerminalControlEvent>.Continuation

    init(service: any SSHServicing, sessionName: String, fontSize: CGFloat = TerminalAppearance.defaultFontSize) {
        self.service = service
        self.sessionName = sessionName
        (controlStream, controlContinuation) = AsyncStream<TerminalControlEvent>.makeStream()
        terminalView = ScrollingTerminalView(frame: .zero, font: TerminalAppearance.font(size: fontSize))
        TerminalAppearance.apply(to: terminalView)
        terminalView.terminalDelegate = self
        start()
    }

    // MARK: - Ciclo de vida

    private func start() {
        guard task == nil else { return }
        generation += 1
        let current = generation
        status = .connecting

        let (outputStream, outputCont) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .bufferingNewest(4096))
        let terminal = terminalView.getTerminal()
        let cols = max(terminal.cols, 20)
        let rows = max(terminal.rows, 5)
        let service = self.service
        let name = self.sessionName
        let control = self.controlStream

        task = Task { [weak self] in
            let feeder = Task { @MainActor [weak self] in
                for await bytes in outputStream {
                    guard let self, self.generation == current else { continue }
                    self.terminalView.feed(byteArray: bytes[...])
                    self.scheduleReveal()
                }
            }
            do {
                try await service.attachTerminal(
                    session: name, initialCols: cols, initialRows: rows, control: control, output: outputCont
                )
                self?.finish(error: nil, generation: current)
            } catch is CancellationError {
                // Parada normal (cerrar el terminal o pasar a segundo plano).
            } catch {
                self?.finish(error: error, generation: current)
            }
            feeder.cancel()
        }
    }

    /// Detach: cierra el canal (tmux desengancha este cliente; la sesión sigue viva).
    func stop() {
        _ = detach()
    }

    /// Como `stop()`, pero espera a que el canal se cierre de verdad (segundo plano:
    /// el FIN debe salir antes de que iOS congele la app).
    func stopAndWait() async {
        await detach()?.value
    }

    private func detach() -> Task<Void, Never>? {
        generation += 1
        controlContinuation.finish()
        revealTask?.cancel()
        revealTask = nil
        let running = task
        running?.cancel()
        task = nil
        return running
    }

    /// Reabre el PTY (tras volver de segundo plano o tras un error de red).
    func reconnect() {
        stop()
        (controlStream, controlContinuation) = AsyncStream<TerminalControlEvent>.makeStream()
        terminalView.getTerminal().resetToInitialState()
        start()
        let terminal = terminalView.getTerminal()
        controlContinuation.yield(.resize(cols: terminal.cols, rows: terminal.rows))
    }

    /// `true` si el PTY ya no está vivo y hay que reconectar al volver a primer plano.
    var needsReconnect: Bool {
        switch status {
        case .ended, .failed: return true
        case .connecting, .connected: return task == nil
        }
    }

    /// Envía texto o secuencias (p. ej. desde la barra de atajos) al PTY.
    func send(_ bytes: [UInt8]) {
        controlContinuation.yield(.input(bytes))
    }

    /// Pega texto respetando el modo «bracketed paste» de la app remota: así un texto
    /// con saltos de línea no se ejecuta línea a línea en el shell.
    func paste(_ text: String) {
        let bytes = Array(text.utf8)
        if terminalView.getTerminal().bracketedPasteMode {
            send(Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8))
        } else {
            send(bytes)
        }
    }

    // MARK: - Portapapeles, imágenes y archivos

    /// Pega lo que haya en el portapapeles: una imagen se sube al servidor y se escribe
    /// su ruta (como al pegar en el Mac); el texto se pega tal cual.
    func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let image = pasteboard.image, let png = image.pngData() {
            upload(label: "imagen") { service in try await service.uploadPastedFile(data: png, fileExtension: "png") }
        } else if let text = pasteboard.string {
            paste(text)
        } else {
            show(.failed("El portapapeles está vacío."))
        }
    }

    /// Sube un archivo o foto al servidor (ruta privada en /tmp) y escribe su ruta en el
    /// prompt, para que la app remota (p. ej. Claude Code) la lea.
    func attach(data: Data, fileName: String) {
        guard data.count <= TerminalAttachment.maxBytes else {
            show(.failed(TerminalAttachment.tooLargeMessage(fileName: fileName)))
            return
        }
        upload(label: fileName) { service in try await service.uploadDroppedFile(data: data, originalName: fileName) }
    }

    /// Texto del panel activo con su historial, para seleccionarlo con iOS.
    func capturedText() async throws -> String {
        try await service.capturePaneText(session: sessionName)
    }

    private func upload(label: String, _ operation: @escaping @Sendable (any SSHServicing) async throws -> String) {
        let service = self.service
        notice = .uploading(label)
        noticeTask?.cancel()
        Task { @MainActor [weak self] in
            do {
                let remotePath = try await operation(service)
                self?.send(Array((remotePath + " ").utf8))
                self?.show(.uploaded(label))
            } catch {
                Log.terminal.error("No se pudo subir \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self?.show(.failed("No se pudo subir «\(label)»: \(error.userMessage)"))
            }
        }
    }

    func show(_ newNotice: TerminalNotice) {
        notice = newNotice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: newNotice.duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func scheduleReveal() {
        guard status == .connecting, revealTask == nil else { return }
        let current = generation
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.generation == current, self.status == .connecting else { return }
            self.status = .connected
        }
    }

    private func finish(error: Error?, generation finished: Int) {
        guard finished == generation else { return }
        task = nil
        if let error {
            status = .failed(error.userMessage)
        } else {
            status = .ended
        }
    }

    // MARK: - TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { controlContinuation.yield(.input(bytes)) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { controlContinuation.yield(.resize(cols: newCols, rows: newRows)) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            UIPasteboard.general.string = text
            show(.copied)
        }
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Aviso breve que se muestra sobre el terminal.
enum TerminalNotice: Equatable {
    case copied
    case uploading(String)
    case uploaded(String)
    case failed(String)

    var text: String {
        switch self {
        case .copied: return "Copiado"
        case .uploading(let name): return "Subiendo «\(name)»…"
        case .uploaded(let name): return "«\(name)» subido: su ruta está en el prompt"
        case .failed(let message): return message
        }
    }

    var symbolName: String {
        switch self {
        case .copied: return "doc.on.doc.fill"
        case .uploading: return "arrow.up.circle"
        case .uploaded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var duration: Duration {
        switch self {
        case .failed: return .seconds(5)
        case .uploading: return .seconds(120)
        default: return .seconds(2)
        }
    }
}

/// Tipografía y colores del terminal en iPhone/iPad.
enum TerminalAppearance {
    static let defaultFontSize: CGFloat = 12
    static let fontSizeKey = "terminal.fontSize"

    static func font(size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func apply(to view: TerminalView) {
        view.nativeBackgroundColor = UIColor(white: 0.07, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.backgroundColor = view.nativeBackgroundColor
        view.keyboardAppearance = .dark
        view.optionAsMetaKey = true
    }
}
