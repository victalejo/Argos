//
//  SSHServerMetrics.swift
//  ArgosCore
//
//  Historial de recursos y huérfanos de Claude por el canal de comandos: instalar o quitar
//  el muestreo (script por SFTP + temporizador de los encargos), leer un rango, listar los
//  huérfanos y matarlos. Los comandos los construyen `ServerMetricsScript` y
//  `ClaudeOrphanScript`.
//

import Foundation

enum ServerMetricsError: LocalizedError, Equatable {
    /// El servidor no tiene temporizador (ni systemd --user, ni launchd, ni cron).
    case noTimer

    var errorDescription: String? {
        switch self {
        case .noTimer:
            return String(localized: "El servidor no tiene systemd, launchd ni cron para tomar una muestra cada minuto.")
        }
    }
}

extension SSHService {

    func serverMetricsHistory(range: ServerMetricsRange) async throws -> ServerMetricsHistory {
        let output = try await runChecked(
            RemoteTimeout.wrap(ServerMetricsScript.historyCommand(range)),
            failureMessage: String(localized: "No se pudo leer el historial de recursos.")
        )
        return ServerMetricsHistory.parse(output)
    }

    /// Deja el muestreo puesto: el despachador al día (es quien lo llama cada minuto), el
    /// script y el temporizador. Toma una primera muestra.
    @discardableResult
    func installServerMetrics() async throws -> ClaudeTaskTimer.Kind {
        try await ensureTaskDispatcher()
        try await writeHomeFilePrivately(Data(ServerMetricsScript.script.utf8), to: ServerMetricsScript.scriptRelativePath)
        let timer = try await installTaskTimer()
        guard timer != .none else { throw ServerMetricsError.noTimer }
        _ = try await runChecked(
            RemoteTimeout.wrap(ServerMetricsScript.sampleNowCommand),
            failureMessage: String(localized: "No se pudo tomar la primera muestra.")
        )
        return timer
    }

    func uninstallServerMetrics() async throws {
        _ = try await runChecked(
            ServerMetricsScript.uninstallCommand,
            failureMessage: String(localized: "No se pudo quitar el historial de recursos.")
        )
    }

    func claudeProcessSurvey() async throws -> ClaudeProcessSurvey {
        let output = try await runChecked(
            RemoteTimeout.wrap(ClaudeOrphanScript.listCommand),
            failureMessage: String(localized: "No se pudieron leer los procesos de Claude.")
        )
        return ClaudeProcessSurvey.parse(output)
    }

    func killClaudeOrphans(_ orphans: [ClaudeOrphan]) async throws -> [Int: ClaudeOrphanKillOutcome] {
        let output = try await runChecked(
            RemoteTimeout.wrap(ClaudeOrphanScript.killCommand(orphans.map { ($0.pid, $0.fingerprint) })),
            failureMessage: String(localized: "No se pudieron cerrar los procesos.")
        )
        return ClaudeOrphanScript.parseKill(output)
    }
}
