//
//  SessionsViewModel+Poll.swift
//  ArgosCore
//
//  Una vuelta del sondeador (`WorkspacePoller`) sobre UN servidor: un solo comando con
//  estado de Claude, sesiones, solicitudes de puertos y memoria; después el resumen git (si toca o
//  si Claude acaba de terminar) y el CI vigilado. Todo como trabajo de fondo.
//

import Foundation

/// Lo que deja una vuelta para quien avisa (notificaciones, solicitudes de puertos).
struct WorkspacePollRound: Sendable {
    let transitions: [ClaudeTransition]
    let ciResults: [CIResult]
    /// `nil` si no se pidieron o no llegaron completas (se conserva lo último).
    let portRequests: [PortForwardRequest]?
    /// Ventanas de uso de Claude que acaban de pasar al 85 % (o al 95 %).
    var limitAlerts: [ClaudeLimitAlert] = []
}

extension SessionsViewModel {

    /// Una vuelta. `nil` si el servidor no está cargado o la lectura falló (el fallo ya
    /// quedó anotado con `noteBackgroundFailure`).
    func pollWorkspace(_ sections: Set<WorkspacePollSection> = Set(WorkspacePollSection.allCases)) async -> WorkspacePollRound? {
        guard case .loaded(let before) = state, !isRefreshing else { return nil }
        let output: WorkspacePollOutput
        do {
            output = try await ConnectionPriority.background { try await service.workspacePoll(sections) }
        } catch {
            noteBackgroundFailure(error, during: "sondear el servidor")
            return nil
        }
        // Cancelada mientras esperaba (view model rehecho, sondeo parado): nada de lo leído
        // se aplica y no se lanza nada más con este servicio.
        guard !Task.isCancelled else { return nil }
        absorbSessions(output.sessions, readOver: before)
        if let memory = output.memory { absorbMemory(memory) }
        let limitAlerts = output.limitsChecked ? absorbLimits(output.limits) : []
        var transitions: [ClaudeTransition] = []
        if let claude = output.claude { transitions = await absorbClaudeActivity(claude) }
        // Cancelada ya con el estado de Claude aplicado: sus avisos se entregan (si no, un
        // «terminó» se perdería) pero no se usa más el servicio.
        guard !Task.isCancelled else {
            return WorkspacePollRound(transitions: transitions, ciResults: [], portRequests: nil, limitAlerts: limitAlerts)
        }
        // Si Claude acaba de terminar, el resumen git se relee ya: el aviso dice cuántos
        // archivos cambió y la fila del proyecto se actualiza al momento.
        await refreshGitSummaries(force: transitions.contains { $0.activity == .done })
        let ciResults = await pollCIWatches()
        return WorkspacePollRound(
            transitions: transitions, ciResults: ciResults, portRequests: output.portRequests, limitAlerts: limitAlerts
        )
    }

    private func absorbSessions(_ result: SessionsPollResult?, readOver before: [TmuxSession]) {
        switch result {
        case .sessions(let fresh):
            adoptQuietSessions(fresh, readOver: before)
        case .tmuxMissing:
            Log.ssh.notice("Sondeo: tmux ya no está en el servidor; se conserva la lista.")
        case .failed(let code, let message):
            Log.ssh.notice("Sondeo: tmux list-sessions falló (\(code, privacy: .public)): \(message, privacy: .public)")
        case nil:
            break
        }
    }
}
