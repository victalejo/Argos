//
//  UploadQueue.swift
//  ArgosCore
//
//  Estado puro de la cola de subidas del terminal (capturas pegadas, archivos soltados o
//  adjuntados): se suben de una en una, en orden, y cada una informa de su progreso.
//  Inmutable: cada cambio devuelve una cola nueva.
//

import Foundation

/// Un archivo de la cola.
struct UploadQueueItem: Identifiable, Equatable, Sendable {

    enum State: Equatable, Sendable {
        case waiting
        case uploading(sentBytes: Int)
        case done(remotePath: String)
        case failed(message: String)
    }

    let id: UUID
    let name: String
    let totalBytes: Int
    let state: State

    init(id: UUID = UUID(), name: String, totalBytes: Int, state: State = .waiting) {
        self.id = id
        self.name = name
        self.totalBytes = max(0, totalBytes)
        self.state = state
    }

    func with(state: State) -> UploadQueueItem {
        UploadQueueItem(id: id, name: name, totalBytes: totalBytes, state: state)
    }

    /// Bytes ya enviados (un archivo terminado cuenta entero).
    var sentBytes: Int {
        switch state {
        case .waiting, .failed: return 0
        case .uploading(let sent): return min(max(0, sent), totalBytes)
        case .done: return totalBytes
        }
    }

    /// Progreso de este archivo, de 0 a 1.
    var fraction: Double {
        if case .done = state { return 1 }
        guard totalBytes > 0 else { return 0 }
        return Double(sentBytes) / Double(totalBytes)
    }

    var isPending: Bool {
        switch state {
        case .waiting, .uploading: return true
        case .done, .failed: return false
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

struct UploadQueue: Equatable, Sendable {

    let items: [UploadQueueItem]

    init(items: [UploadQueueItem] = []) {
        self.items = items
    }

    // MARK: - Cambios

    func appending(_ newItems: [UploadQueueItem]) -> UploadQueue {
        UploadQueue(items: items + newItems)
    }

    func setting(_ state: UploadQueueItem.State, for id: UUID) -> UploadQueue {
        UploadQueue(items: items.map { $0.id == id ? $0.with(state: state) : $0 })
    }

    func removing(_ id: UUID) -> UploadQueue {
        UploadQueue(items: items.filter { $0.id != id })
    }

    /// Quita lo terminado bien; los fallos y lo pendiente se quedan.
    func removingCompleted() -> UploadQueue {
        UploadQueue(items: items.filter { item in
            if case .done = item.state { return false }
            return true
        })
    }

    /// Quita todo lo que ya no está pendiente (terminado o fallido).
    func removingFinished() -> UploadQueue {
        UploadQueue(items: items.filter(\.isPending))
    }

    // MARK: - Consultas

    var isEmpty: Bool { items.isEmpty }

    /// El archivo que se está subiendo.
    var current: UploadQueueItem? {
        items.first { item in
            if case .uploading = item.state { return true }
            return false
        }
    }

    /// El siguiente que toca subir (solo si no hay otro subiendo).
    var next: UploadQueueItem? {
        guard current == nil else { return nil }
        return items.first { $0.state == .waiting }
    }

    var isBusy: Bool { items.contains(where: \.isPending) }

    var failedCount: Int { items.filter(\.isFailed).count }

    /// Archivos de la tanda (sin los fallidos, que ya no avanzan).
    private var batch: [UploadQueueItem] { items.filter { !$0.isFailed } }

    /// Posición (1…) del archivo en curso dentro de la tanda.
    var currentPosition: Int? {
        guard let current else { return nil }
        return batch.firstIndex { $0.id == current.id }.map { $0 + 1 }
    }

    var batchCount: Int { batch.count }

    /// Progreso de toda la tanda por bytes, de 0 a 1.
    var overallFraction: Double {
        let total = batch.reduce(0) { $0 + $1.totalBytes }
        guard total > 0 else {
            // Solo archivos vacíos: cuenta por archivos.
            guard !batch.isEmpty else { return 0 }
            let done = batch.filter { !$0.isPending }.count
            return Double(done) / Double(batch.count)
        }
        let sent = batch.reduce(0) { $0 + $1.sentBytes }
        return Double(sent) / Double(total)
    }

    /// Porcentaje entero (0…100) para mostrar.
    var overallPercent: Int { Int((overallFraction * 100).rounded(.down)) }
}
