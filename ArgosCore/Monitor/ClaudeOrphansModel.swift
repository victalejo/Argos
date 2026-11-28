//
//  ClaudeOrphansModel.swift
//  ArgosCore
//
//  Estado de la vista de procesos de Claude huérfanos (Mac e iPhone/iPad): buscar, marcar
//  y, tras confirmar, cerrar los marcados. El servidor vuelve a comprobar cada uno antes
//  de cada señal; aquí solo se elige.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeOrphansModel {

    enum Phase: Equatable {
        case idle
        case scanning
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var orphans: [ClaudeOrphan] = []
    var selection: Set<Int> = []
    private(set) var isKilling = false
    /// Resumen del último cierre (o del error).
    private(set) var notice: String?

    @ObservationIgnored private let service: any SSHServicing

    init(service: any SSHServicing) {
        self.service = service
    }

    var selectedOrphans: [ClaudeOrphan] { orphans.filter { selection.contains($0.pid) } }

    var selectedRSSKB: Int { selectedOrphans.reduce(0) { $0 + $1.totalRSSKB } }

    var canKill: Bool { !selection.isEmpty && !isKilling && phase == .loaded }

    func toggle(_ orphan: ClaudeOrphan) {
        if selection.contains(orphan.pid) {
            selection.remove(orphan.pid)
        } else {
            selection.insert(orphan.pid)
        }
    }

    func scan() async {
        phase = .scanning
        do {
            let survey = try await ConnectionPriority.background { try await self.service.claudeProcessSurvey() }
            apply(survey.orphans())
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Huérfanos de Claude: \(error.userMessage, privacy: .public)")
            phase = .failed(error.userMessage)
        }
    }

    /// Cierra los marcados (como mucho `ClaudeOrphanScript.maxTargets`) y vuelve a buscar.
    func killSelected() async {
        let targets = Array(selectedOrphans.prefix(ClaudeOrphanScript.maxTargets))
        guard !targets.isEmpty else { return }
        isKilling = true
        notice = nil
        defer { isKilling = false }
        do {
            let outcomes = try await service.killClaudeOrphans(targets)
            notice = Self.summary(outcomes, requested: targets.map(\.pid))
            await scan()
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Cerrar huérfanos de Claude: \(error.userMessage, privacy: .public)")
            notice = error.userMessage
        }
    }

    private func apply(_ found: [ClaudeOrphan]) {
        orphans = found
        selection = selection.intersection(Set(found.map(\.pid)))
    }

    /// Frase con lo que pasó. Un PID sin respuesta cuenta como no tocado.
    nonisolated static func summary(_ outcomes: [Int: ClaudeOrphanKillOutcome], requested: [Int]) -> String {
        let killed = requested.filter { outcomes[$0] == .killed }.count
        let stuck = requested.filter { outcomes[$0] == .stuck }.count
        let skipped = requested.count - killed - stuck
        var parts: [String] = []
        if killed > 0 { parts.append(String(localized: "Cerrados: \(killed).")) }
        if stuck > 0 { parts.append(String(localized: "Siguen vivos tras KILL: \(stuck).")) }
        if skipped > 0 {
            parts.append(String(localized: "Sin tocar porque ya no estaban o dejaron de ser huérfanos: \(skipped)."))
        }
        return parts.joined(separator: " ")
    }
}
