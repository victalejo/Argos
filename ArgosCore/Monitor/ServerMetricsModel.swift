//
//  ServerMetricsModel.swift
//  ArgosCore
//
//  Estado de la vista «Historial» de recursos (Mac e iPhone/iPad): rango elegido, lo leído
//  del servidor y las acciones de guardar o dejar de guardar el historial.
//

import Foundation
import Observation

@MainActor
@Observable
final class ServerMetricsModel {

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var range: ServerMetricsRange = .sixHours {
        didSet { if range != oldValue { reloadToken += 1 } }
    }
    private(set) var phase: Phase = .loading
    private(set) var history = ServerMetricsHistory()
    private(set) var isWorking = false
    private(set) var actionError: String?
    /// Cambia para volver a cargar (la vista lo usa como `task(id:)`).
    private(set) var reloadToken = 0

    /// Puntos que pinta la gráfica (como mucho este número).
    static let chartPoints = 288

    @ObservationIgnored private let service: any SSHServicing

    init(service: any SSHServicing) {
        self.service = service
    }

    var chartPoints: [ServerMetricsPoint] {
        ServerMetricsHistory.downsample(history.points, maxPoints: Self.chartPoints)
    }

    /// Marcas de OOM dentro del rango que se ve.
    var visibleOOMMarks: [ServerOOMMark] {
        guard let first = history.points.first?.date else { return history.oomMarks }
        return history.oomMarks.filter { $0.date >= first.addingTimeInterval(-TimeInterval(ServerMetricsScript.aggregateSeconds)) }
    }

    func load() async {
        do {
            let range = self.range
            history = try await ConnectionPriority.background { try await self.service.serverMetricsHistory(range: range) }
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Historial de recursos: \(error.userMessage, privacy: .public)")
            phase = .failed(error.userMessage)
        }
    }

    func retry() {
        Task { await service.resetConnectionHealth() }
        reloadToken += 1
    }

    func install() async {
        await perform { _ = try await self.service.installServerMetrics() }
    }

    func uninstall() async {
        await perform { try await self.service.uninstallServerMetrics() }
    }

    private func perform(_ action: @escaping @Sendable () async throws -> Void) async {
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await action()
            await load()
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Historial de recursos (acción): \(error.userMessage, privacy: .public)")
            actionError = error.userMessage
        }
    }
}
