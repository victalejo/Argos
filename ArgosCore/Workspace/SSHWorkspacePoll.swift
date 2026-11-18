//
//  SSHWorkspacePoll.swift
//  ArgosCore
//
//  La vuelta del sondeador por la conexión compartida: un solo `exec` con todas las
//  secciones pedidas (ver `WorkspacePollCommand`), con plazo también en el servidor.
//

import Foundation

extension SSHService {

    func workspacePoll(_ sections: Set<WorkspacePollSection>) async throws -> WorkspacePollOutput {
        guard !sections.isEmpty else { return WorkspacePollOutput() }
        let client = try await connectedClient()
        let command = RemoteTimeout.wrap(WorkspacePollCommand.script(for: sections))
        let result = try await capture(client, command: command)
        if result.exitCode == RemoteTimeout.expiredExitCode {
            Log.ssh.notice("Sondeo agrupado cortado por el plazo remoto: se usa lo que llegó completo.")
        }
        return WorkspacePollCommand.parse(result.stdout, requested: sections)
    }
}

extension SSHServicing {

    /// Para los dobles de prueba (y cualquier servicio que no tenga el comando agrupado):
    /// la misma vuelta con las llamadas sueltas de siempre.
    func workspacePoll(_ sections: Set<WorkspacePollSection>) async throws -> WorkspacePollOutput {
        var output = WorkspacePollOutput()
        if sections.contains(.claude) {
            output.claude = try await claudeActivity()
        }
        if sections.contains(.sessions) {
            do {
                output.sessions = .sessions(try await listSessions())
            } catch SSHService.SSHServiceError.tmuxNotInstalled {
                output.sessions = .tmuxMissing
            }
        }
        if sections.contains(.ports) {
            output.portRequests = try await pendingPortForwardRequests()
        }
        return output
    }
}
