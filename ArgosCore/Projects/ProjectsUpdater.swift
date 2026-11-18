//
//  ProjectsUpdater.swift
//  Argos
//
//  Lee-modifica-escribe de projects.json sin pisar cambios ajenos (lógica pura, la red
//  entra por closures):
//   1. lee el archivo y recuerda su huella (`cksum`);
//   2. aplica el cambio sobre lo leído (conservando lo desconocido: `ProjectsDocument`);
//   3. el servidor, con un cerrojo, comprueba justo antes del `mv` que la huella sigue
//      siendo la leída; si otro dispositivo lo cambió entretanto, NO escribe y aquí se
//      relee y se reaplica el cambio (hasta `maxAttempts` veces).
//  Dentro de la app, `SerialQueue` pone en fila las escrituras de un mismo servidor
//  (p. ej. `setMacCheckout` y `saveProject` a la vez).
//

import Foundation

enum ProjectsWriteOutcome: Equatable, Sendable {
    case written
    /// El archivo cambió desde que se leyó: no se escribió nada.
    case conflict
}

enum ProjectsUpdater {
    static let maxAttempts = 4

    /// Huella esperada del archivo leído: `nil` = vacío o inexistente.
    static func expectedFingerprint(of text: String) -> String? {
        text.isEmpty ? nil : PosixChecksum.fingerprint(of: Data(text.utf8))
    }

    static func run(
        read: () async throws -> String,
        write: (_ data: Data, _ expected: String?) async throws -> ProjectsWriteOutcome,
        transform: ([Project]) throws -> [Project]
    ) async throws -> ProjectsLoadReport {
        for attempt in 1...maxAttempts {
            let text = try await read()
            let document = try ProjectsDocument.parse(text)
            let updated = try document.replacingProjects(try transform(document.projects))
            let data = try updated.encoded()
            if data == Data(text.utf8) { return ProjectsLoadReport(document: updated) }
            switch try await write(data, expectedFingerprint(of: text)) {
            case .written:
                return ProjectsLoadReport(document: updated)
            case .conflict:
                Log.store.notice("projects.json cambió mientras se guardaba (intento \(attempt)); se relee.")
            }
        }
        throw ProjectError.writeConflict
    }
}

/// Fila FIFO de operaciones asíncronas por clave (una a la vez por clave).
actor SerialQueue {
    static let projects = SerialQueue()

    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func run<T: Sendable>(key: String, _ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire(key)
        defer { release(key) }
        return try await operation()
    }

    private func acquire(_ key: String) async {
        guard busy.contains(key) else {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(key)
        }
    }
}
