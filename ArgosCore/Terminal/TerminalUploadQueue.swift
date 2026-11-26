//
//  TerminalUploadQueue.swift
//  ArgosCore
//
//  Cola de subidas del terminal (Mac e iPhone/iPad): lo que se pega, suelta o adjunta
//  mientras otra subida está en curso espera su turno en vez de perderse. Sube de una
//  en una por SFTP (`SSHServicing.uploadDroppedFile`/`uploadPastedFile`), publica el
//  progreso y, al terminar cada archivo, entrega su ruta remota para escribirla en el
//  prompt. Se puede cancelar o reintentar cada archivo.
//

import Foundation
import Observation

/// Qué subir y cómo nombrarlo en el servidor.
struct TerminalUploadRequest: Sendable {

    enum Source: Sendable {
        /// Bytes ya en memoria (imagen pegada, foto de la fototeca, archivo de iOS).
        case data(Data)
        /// Archivo local que se lee al llegarle el turno (soltado desde Finder).
        case file(URL)
    }

    enum Destination: Sendable, Equatable {
        /// `/tmp/argos-pasted-….ext`
        case pasted(fileExtension: String)
        /// `/tmp/argos-…-nombre` (conserva el nombre saneado).
        case named(originalName: String)
    }

    let name: String
    let size: Int
    let source: Source
    let destination: Destination

    static func pastedImage(_ data: Data, fileExtension: String) -> TerminalUploadRequest {
        TerminalUploadRequest(
            name: String(localized: "Imagen pegada"),
            size: data.count,
            source: .data(data),
            destination: .pasted(fileExtension: fileExtension)
        )
    }

    static func attachment(_ data: Data, fileName: String) -> TerminalUploadRequest {
        TerminalUploadRequest(
            name: fileName, size: data.count, source: .data(data), destination: .named(originalName: fileName)
        )
    }

    /// Archivo local; el tamaño se lee de sus atributos (0 si no se puede).
    static func localFile(_ url: URL) -> TerminalUploadRequest {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return TerminalUploadRequest(
            name: url.lastPathComponent, size: size, source: .file(url),
            destination: .named(originalName: url.lastPathComponent)
        )
    }
}

@MainActor
@Observable
final class TerminalUploadQueue {

    private(set) var queue = UploadQueue()

    /// Recibe la ruta remota de cada archivo subido (se escribe en el prompt).
    @ObservationIgnored var onUploaded: (@MainActor (String) -> Void)?

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored private var requests: [UUID: TerminalUploadRequest] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var currentTask: Task<String, Error>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    /// Último porcentaje publicado del archivo en curso (evita repintar por cada bloque).
    @ObservationIgnored private var lastPublishedPercent = -1
    @ObservationIgnored private let maxBytes: Int
    @ObservationIgnored private let completedLinger: Duration

    init(
        service: any SSHServicing,
        maxBytes: Int = TerminalAttachment.maxBytes,
        completedLinger: Duration = .seconds(2)
    ) {
        self.service = service
        self.maxBytes = maxBytes
        self.completedLinger = completedLinger
    }

    // MARK: - Acciones

    /// Añade archivos al final de la cola y arranca si estaba parada.
    func enqueue(_ newRequests: [TerminalUploadRequest]) {
        guard !newRequests.isEmpty else { return }
        cleanupTask?.cancel()
        let items = newRequests.map { request -> UploadQueueItem in
            let item = UploadQueueItem(name: request.name, totalBytes: request.size)
            guard request.size <= maxBytes else {
                return item.with(state: .failed(message: TerminalAttachment.tooLargeMessage(fileName: request.name)))
            }
            requests[item.id] = request
            return item
        }
        queue = queue.appending(items)
        startIfNeeded()
    }

    /// Quita un archivo: si se está subiendo, corta la subida.
    func cancel(_ id: UUID) {
        if queue.current?.id == id {
            currentTask?.cancel()
        }
        requests[id] = nil
        queue = queue.removing(id)
        scheduleCleanupIfIdle()
    }

    /// Vuelve a poner en cola un archivo que falló.
    func retry(_ id: UUID) {
        guard requests[id] != nil,
              let item = queue.items.first(where: { $0.id == id }), item.isFailed else { return }
        cleanupTask?.cancel()
        queue = queue.setting(.waiting, for: id)
        startIfNeeded()
    }

    /// Cierra el panel: quita lo terminado y lo fallido.
    func dismissFinished() {
        for item in queue.items where !item.isPending {
            requests[item.id] = nil
        }
        queue = queue.removingFinished()
    }

    /// Corta todo (el terminal se cierra).
    func cancelAll() {
        worker?.cancel()
        currentTask?.cancel()
        cleanupTask?.cancel()
        worker = nil
        requests = [:]
        queue = UploadQueue()
    }

    // MARK: - Proceso

    private func startIfNeeded() {
        guard worker == nil, queue.next != nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let item = queue.next {
            await upload(item)
        }
        worker = nil
        scheduleCleanupIfIdle()
    }

    private func upload(_ item: UploadQueueItem) async {
        guard let request = requests[item.id] else {
            queue = queue.removing(item.id)
            return
        }
        lastPublishedPercent = -1
        queue = queue.setting(.uploading(sentBytes: 0), for: item.id)
        let task = makeUploadTask(request, id: item.id)
        currentTask = task
        let result = await task.result
        currentTask = nil
        // Cancelado por el usuario: `cancel(_:)` ya lo quitó de la cola.
        guard queue.items.contains(where: { $0.id == item.id }) else { return }
        switch result {
        case .success(let remotePath):
            requests[item.id] = nil
            queue = queue.setting(.done(remotePath: remotePath), for: item.id)
            onUploaded?(remotePath)
        case .failure(let error):
            Log.terminal.error("Fallo al subir \(item.name, privacy: .public): \(error.userMessage, privacy: .public)")
            queue = queue.setting(.failed(message: error.userMessage), for: item.id)
        }
    }

    private func makeUploadTask(_ request: TerminalUploadRequest, id: UUID) -> Task<String, Error> {
        let service = self.service
        let progress: UploadProgressHandler = { [weak self] sent in
            Task { @MainActor in self?.publishProgress(sent, for: id) }
        }
        return Task {
            let data = try await Self.load(request.source)
            switch request.destination {
            case .pasted(let fileExtension):
                return try await service.uploadPastedFile(data: data, fileExtension: fileExtension, progress: progress)
            case .named(let originalName):
                return try await service.uploadDroppedFile(data: data, originalName: originalName, progress: progress)
            }
        }
    }

    private func publishProgress(_ sent: Int, for id: UUID) {
        guard let current = queue.current, current.id == id else { return }
        let percent = current.totalBytes > 0 ? sent * 100 / current.totalBytes : 0
        guard percent != lastPublishedPercent else { return }
        lastPublishedPercent = percent
        queue = queue.setting(.uploading(sentBytes: sent), for: id)
    }

    /// Lee el archivo fuera del hilo principal (puede pesar decenas de MB).
    private nonisolated static func load(_ source: TerminalUploadRequest.Source) async throws -> Data {
        switch source {
        case .data(let data):
            return data
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
        }
    }

    /// Sin nada pendiente: lo subido bien desaparece tras un momento; los fallos se quedan.
    private func scheduleCleanupIfIdle() {
        guard !queue.isBusy, !queue.isEmpty else { return }
        cleanupTask?.cancel()
        let linger = completedLinger
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled, let self, !self.queue.isBusy else { return }
            for item in self.queue.items where !item.isFailed {
                self.requests[item.id] = nil
            }
            self.queue = self.queue.removingCompleted()
        }
    }
}
