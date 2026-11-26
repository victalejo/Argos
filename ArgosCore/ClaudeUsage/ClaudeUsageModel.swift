//
//  ClaudeUsageModel.swift
//  ArgosCore
//
//  Pantalla de uso de tokens de Claude (Mac e iPhone/iPad): lee el índice del servidor y,
//  si está viejo, falló o no existe, lo recalcula en segundo plano y espera a que termine.
//  Las lecturas van como trabajo de fondo (`ConnectionPriority`).
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeUsageModel {

    enum Phase: Equatable {
        case loading
        /// Calculando en el servidor sin datos previos (la primera vez puede tardar minutos).
        case indexing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var snapshot: ClaudeUsageSnapshot?
    /// Se está recalculando en el servidor mientras se enseñan los datos anteriores.
    private(set) var isUpdating = false
    var range: ClaudeUsageRange = .week
    /// Cambia al pedir «Reintentar»: la vista relanza la carga con `.task(id:)` (estructurada,
    /// se cancela al cerrar la hoja).
    private(set) var reloadToken = 0

    /// Con un índice más viejo que esto, se recalcula al abrir.
    static let staleAfter: TimeInterval = 5 * 60
    /// Cada cuánto se mira si terminó el cálculo.
    static let pollInterval: Duration = .seconds(3)
    /// Cuánto se espera como mucho a un cálculo (luego se enseña lo que haya).
    static let maxWait: Duration = .seconds(15 * 60)

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored private let projectNames: [String: String]
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let maxWait: Duration

    init(
        service: any SSHServicing,
        projects: [Project],
        pollInterval: Duration = ClaudeUsageModel.pollInterval,
        maxWait: Duration = ClaudeUsageModel.maxWait
    ) {
        self.service = service
        self.projectNames = ClaudeUsageProjects.names(for: projects)
        self.pollInterval = pollInterval
        self.maxWait = maxWait
    }

    func summary(now: Date = Date()) -> ClaudeUsageSummary? {
        snapshot.map { ClaudeUsageSummary.make($0.records, range: range, projectNames: projectNames, now: now) }
    }

    func retry() {
        reloadToken += 1
    }

    /// Lee y, si hace falta, recalcula. Tras «Reintentar» (`reloadToken > 0`) recalcula siempre.
    func load(now: Date = Date()) async {
        let force = reloadToken > 0
        do {
            let first = try await read()
            snapshot = first
            if case .done(let at) = first.status, !force, now.timeIntervalSince(at) < Self.staleAfter {
                phase = .ready
                return
            }
            phase = first.records.isEmpty ? .indexing : .ready
            // También con un cálculo «en marcha»: si de verdad corre, el script sale sin hacer
            // nada; si murió (cerrojo huérfano), así se recupera.
            try await ConnectionPriority.background { try await self.service.startClaudeUsageIndex() }
            try await waitForIndex()
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Uso de Claude: \(error.userMessage, privacy: .public)")
            // Con datos ya enseñados, un fallo pasajero no los esconde.
            if snapshot?.records.isEmpty == false {
                phase = .ready
            } else {
                phase = .failed(error.userMessage)
            }
        }
    }

    private func read() async throws -> ClaudeUsageSnapshot {
        try await ConnectionPriority.background { try await self.service.readClaudeUsage() }
    }

    private func waitForIndex() async throws {
        isUpdating = true
        defer { isUpdating = false }
        let deadline = ContinuousClock.now + maxWait
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            let next = try await read()
            snapshot = next
            switch next.status {
            case .running:
                continue
            case .failed:
                throw ClaudeUsageError.indexFailed
            case .done, .never:
                phase = .ready
                return
            }
        }
        if snapshot?.records.isEmpty != false { throw ClaudeUsageError.stillIndexing }
        phase = .ready
    }
}

enum ClaudeUsageError: LocalizedError, Equatable {
    case indexFailed
    case stillIndexing

    var errorDescription: String? {
        switch self {
        case .indexFailed:
            return String(localized: "El cálculo del uso falló en el servidor (¿disco lleno?). Vuelve a intentarlo.")
        case .stillIndexing:
            return String(localized: "El cálculo sigue en marcha en el servidor. Vuelve a abrir esta pantalla en unos minutos.")
        }
    }
}
