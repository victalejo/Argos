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
    let terminalView: ArgosTerminalView

    /// Estado de la conexión (para feedback en la UI).
    private(set) var status: LiveTerminalStatus = .connecting

    /// `true` mientras se sube una imagen pegada por SFTP (feedback en la UI).
    private(set) var isUploading = false

    private let service: any SSHServicing
    private let sessionName: String

    private var task: Task<Void, Never>?
    private var isStopping = false

    /// Monitor local de eventos de rueda (reenvía el scroll al PTY; ver `forwardWheel`).
    private var scrollMonitor: Any?

    /// Tarea que revela el terminal tras un breve margen desde la primera salida,
    /// dando tiempo a que tmux repinte la pantalla (evita el "flash" negro de attach).
    private var revealTask: Task<Void, Never>?

    // Stream de control (teclas / resize). Se crea en `init` como `let` Sendable para
    // que los métodos `nonisolated` del delegate puedan encolar directamente, sin saltar
    // de actor: así las pulsaciones conservan su orden y no se introduce latencia.
    private let controlStream: AsyncStream<TerminalControlEvent>
    private let controlContinuation: AsyncStream<TerminalControlEvent>.Continuation

    init(service: any SSHServicing, sessionName: String) {
        self.service = service
        self.sessionName = sessionName
        let (controlStream, controlContinuation) = AsyncStream<TerminalControlEvent>.makeStream()
        self.controlStream = controlStream
        self.controlContinuation = controlContinuation
        self.terminalView = ArgosTerminalView(frame: .zero)
        self.terminalView.terminalDelegate = self
        installClipboardHandler()
        self.terminalView.enableFileDrop()
        self.terminalView.onPasteImage = { [weak self] data, ext in
            self?.handlePastedImage(data, fileExtension: ext)
        }
        self.terminalView.onDropFiles = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }
        installScrollMonitor()
        start()
    }

    /// Instala un monitor local de rueda: cuando el puntero está sobre nuestro terminal
    /// y la app tiene mouse reporting activo, reenvía el scroll al PTY y consume el evento
    /// (devuelve `nil`) para que SwiftTerm no haga además su scroll local.
    private func installScrollMonitor() {
        // Strict concurrency avisa de que `NSEvent` no es Sendable al cruzar al closure
        // @MainActor de `assumeIsolated`. Es seguro: los monitores LOCALES de eventos se
        // entregan SIEMPRE en el hilo principal, así que ya estamos en el MainActor; el
        // `assumeIsolated` solo lo formaliza. Es la fricción conocida AppKit + Swift 6 con
        // monitores de eventos (warning en modo Swift 5; no se sube a Swift 6 por esto).
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                guard let window = self.terminalView.window, event.window === window else { return event }
                let point = self.terminalView.convert(event.locationInWindow, from: nil)
                guard self.terminalView.bounds.contains(point) else { return event }
                return self.terminalView.forwardWheel(event) ? nil : event
            }
        }
    }

    /// Sube por SFTP cada archivo soltado (conservando su nombre) e inserta sus rutas
    /// remotas en el input del terminal, separadas por espacio.
    private func handleDroppedFiles(_ urls: [URL]) {
        guard !isUploading else { return }
        isUploading = true
        Task { @MainActor in
            defer { isUploading = false }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    Log.terminal.error("No se pudo leer el archivo soltado: \(url.lastPathComponent, privacy: .public)")
                    continue
                }
                do {
                    let remotePath = try await service.uploadDroppedFile(
                        data: data, originalName: url.lastPathComponent
                    )
                    controlContinuation.yield(.input(Array((remotePath + " ").utf8)))
                } catch {
                    Log.terminal.error("Fallo al subir \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Sube por SFTP la imagen pegada y, al terminar, inserta su ruta remota en el
    /// input del terminal (con espacio final) para que la app remota (p. ej. Claude
    /// Code) pueda leerla por ruta.
    private func handlePastedImage(_ data: Data, fileExtension: String) {
        guard !isUploading else { return }
        isUploading = true
        Task { @MainActor in
            defer { isUploading = false }
            do {
                let remotePath = try await service.uploadPastedFile(data: data, fileExtension: fileExtension)
                controlContinuation.yield(.input(Array((remotePath + " ").utf8)))
            } catch {
                Log.terminal.error("Fallo al subir imagen pegada: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Registra un handler propio para OSC 52 directamente en el parser del terminal.
    ///
    /// En macOS, el `TerminalView` de SwiftTerm NO reenvía OSC 52 al `TerminalViewDelegate`
    /// (usa la implementación vacía por defecto de `TerminalDelegate.clipboardCopy`; solo
    /// iOS la sobreescribe). Interceptamos el código 52 en el parser para copiar nosotros
    /// al portapapeles del Mac. El payload es "<selección>;<base64>".
    private func installClipboardHandler() {
        terminalView.getTerminal().registerOscHandler(code: 52) { data in
            guard let semi = data.firstIndex(of: UInt8(ascii: ";")) else { return }
            let base64Start = data.index(after: semi)
            guard base64Start < data.endIndex else { return }
            let base64 = Data(data[base64Start...])
            guard let decoded = Data(base64Encoded: base64),
                  let text = String(data: decoded, encoding: .utf8) else { return }
            Log.terminal.notice("OSC 52 -> portapapeles (\(text.count, privacy: .public) chars)")
            Task { @MainActor in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    // El detach/limpieza lo dispara `stop()`, invocado de forma fiable por el `defer`
    // de la `.task(id:)` del detalle al cambiar de sesión o cerrarse la vista.

    // MARK: - Ciclo de vida

    /// Abre el PTY y conecta los flujos. Idempotente: no relanza si ya hay una tarea.
    private func start() {
        guard task == nil else { return }

        // Buffer ACOTADO: ante salida remota de muy alto volumen (p. ej. Claude Code
        // escupiendo miles de líneas), si el feeder del MainActor no drena a tiempo,
        // se descartan los chunks más viejos en lugar de crecer en memoria sin tope.
        // La entrada (teclas) usa su propio stream sin acotar: nunca se pierden.
        let (outputStream, outputCont) = AsyncStream<[UInt8]>.makeStream(
            bufferingPolicy: .bufferingNewest(4096)
        )

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
                    // Pintamos siempre (tmux repinta DEBAJO del overlay de carga); el
                    // overlay se retira con un margen tras la primera salida, no de golpe
                    // en el primer byte (que es solo el eco de `exec tmux attach`).
                    self.terminalView.feed(byteArray: bytes[...])
                    self.scheduleRevealIfNeeded()
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
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        revealTask?.cancel()
        revealTask = nil
        task?.cancel()
        task = nil
    }

    /// Tras la PRIMERA salida del PTY, espera un margen breve para que tmux repinte
    /// la pantalla y solo entonces marca `.connected` (retira el overlay de carga).
    /// Solo programa una vez; las salidas posteriores no reinician el contador.
    private func scheduleRevealIfNeeded() {
        guard status == .connecting, revealTask == nil else { return }
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !self.isStopping, self.status == .connecting else { return }
            self.status = .connected
        }
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

    /// OSC 52 vía el delegate de SwiftTerm. En macOS este método NO se invoca (la
    /// `TerminalView` no reenvía OSC 52 al delegate); la copia real la hace el handler
    /// registrado en `installClipboardHandler()`. Se mantiene por compatibilidad.
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        Task { @MainActor in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    // Métodos restantes del protocolo sin comportamiento específico para este caso.
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// MARK: - TerminalView que intercepta el pegado de imágenes

/// Subclase de `TerminalView` que detecta cuando el usuario pega (Cmd+V) y el
/// portapapeles del Mac contiene una imagen: en ese caso invoca `onPasteImage` (que
/// la sube al servidor) en lugar de pegar texto. Si no hay imagen, pega normal.
final class ArgosTerminalView: TerminalView {
    /// Invocado al pegar con una imagen en el portapapeles: `(datos, extensión)`.
    var onPasteImage: ((Data, String) -> Void)?
    /// Invocado al soltar archivos desde Finder sobre el terminal: lista de URLs.
    var onDropFiles: (([URL]) -> Void)?

    override func paste(_ sender: Any?) {
        if let (data, ext) = Self.imageFromPasteboard() {
            onPasteImage?(data, ext)
            return
        }
        super.paste(sender as Any)
    }

    // MARK: - Arrastrar y soltar archivos

    /// Registra el tipo arrastrable. SwiftTerm ya maneja drags internos; nos sumamos
    /// para aceptar URLs de archivo soltadas desde Finder.
    func enableFileDrop() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasDraggableFiles(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasDraggableFiles(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }

    private func hasDraggableFiles(_ sender: any NSDraggingInfo) -> Bool {
        !fileURLs(from: sender).isEmpty
    }

    // MARK: - Rueda de scroll

    /// Reenvía la rueda del ratón al PTY si la app remota tiene mouse reporting activo
    /// (tmux con `mouse on` lo activa) y devuelve `true` (evento consumido). Si no,
    /// devuelve `false` para que ocurra el scroll local por defecto de SwiftTerm.
    ///
    /// No se puede sobreescribir `scrollWheel` (SwiftTerm lo declara `public`, no `open`),
    /// por eso el controlador instala un monitor local de eventos que llama aquí.
    func forwardWheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        let reportingActive: Bool
        switch terminal.mouseMode {
        case .off: reportingActive = false
        default: reportingActive = true
        }
        guard allowMouseReporting, reportingActive, event.deltaY != 0 else { return false }

        let button = event.deltaY > 0 ? 4 : 5 // 4 = rueda arriba, 5 = rueda abajo
        let flags = terminal.encodeButton(
            button: button, release: false, shift: false, meta: false, control: false
        )
        let (col, row) = gridPosition(for: event, cols: terminal.cols, rows: terminal.rows)
        let steps = max(1, min(Int(abs(event.deltaY)), 4))
        for _ in 0..<steps {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
        return true
    }

    /// Posición de celda (col,row) bajo el cursor para el evento de rueda.
    private func gridPosition(for event: NSEvent, cols: Int, rows: Int) -> (Int, Int) {
        guard cols > 0, rows > 0, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / (bounds.width / CGFloat(cols)))
        let row = Int((bounds.height - point.y) / (bounds.height / CGFloat(rows)))
        return (min(max(0, col), cols - 1), min(max(0, row), rows - 1))
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL] ?? []
        return objects.filter { $0.isFileURL }
    }

    /// Extrae una imagen del portapapeles como `(datos, extensión)`, o `nil` si no hay.
    /// Prioriza PNG; convierte TIFF (screenshots) a PNG; admite un archivo de imagen
    /// copiado en Finder.
    private static func imageFromPasteboard() -> (Data, String)? {
        let pasteboard = NSPasteboard.general

        if let png = pasteboard.data(forType: .png) {
            return (png, "png")
        }

        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"]
        if let url = NSURL(from: pasteboard) as URL?,
           imageExtensions.contains(url.pathExtension.lowercased()),
           let data = try? Data(contentsOf: url) {
            return (data, url.pathExtension.lowercased())
        }

        return nil
    }
}
