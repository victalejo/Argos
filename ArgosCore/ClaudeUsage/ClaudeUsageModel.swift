//
//  ClaudeUsageModel.swift
//  ArgosCore
//
//  Pantalla de uso de tokens de Claude (Mac e iPhone/iPad): lee el índice del servidor y,
//  si está viejo o no existe, lo recalcula en segundo plano y espera a que termine.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeUsageModel {

    enum Phase: Equatable {
        case loading
        /// Calculando en el servidor (la primera vez puede tardar minutos).
        case indexing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var snapshot: ClaudeUsageSnapshot?
    /// Se está recalculando en el servidor mientras se enseñan los datos anteriores.
    private(set) var isUpdating = false
    var range: ClaudeUsageRange = .week

    /// Con un índice más viejo que esto, se recalcula al abrir.
    static let staleAfter: TimeInterval = 5 * 60
    /// Cada cuánto se mira si terminó el cálculo.
    static let pollInterval: Duration = .seconds(3)
    /// Cuánto se espera como mucho a un cálculo (luego se enseña lo que haya).
    static let maxWait: Duration = .seconds(15 * 60)

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored private let projectNames: [String: String]
    @ObservationIgnored private let pollInterval: Duration

    init(service: any SSHServicing, projects: [Project], pollInterval: Duration = ClaudeUsageModel.pollInterval) {
        self.service = service
        self.projectNames = ClaudeUsageProjects.names(for: projects)
        self.pollInterval = pollInterval
    }

    func summary(now: Date = Date()) -> ClaudeUsageSummary? {
        snapshot.map { ClaudeUsageSummary.make($0.records, range: range, projectNames: projectNames, now: now) }
    }

    /// Lee y, si hace falta, recalcula. `force` recalcula siempre.
    func load(force: Bool = false, now: Date = Date()) async {
        do {
            let first = try await service.readClaudeUsage()
            snapshot = first
            switch first.status {
            case .running:
                phase = first.records.isEmpty ? .indexing : .ready
            case .done(let at) where !force && now.timeIntervalSince(at) < Self.staleAfter:
                phase = .ready
                return
            default:
                phase = first.records.isEmpty ? .indexing : .ready
                try await service.startClaudeUsageIndex()
            }
            try await waitForIndex()
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Uso de Claude: \(error.userMessage, privacy: .public)")
            phase = .failed(error.userMessage)
        }
    }

    private func waitForIndex() async throws {
        isUpdating = true
        defer { isUpdating = false }
        let deadline = ContinuousClock.now + Self.maxWait
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            let next = try await service.readClaudeUsage()
            snapshot = next
            if case .running = next.status { continue }
            phase = .ready
            return
        }
        phase = .ready
    }
}
