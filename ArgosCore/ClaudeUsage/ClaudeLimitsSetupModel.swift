//
//  ClaudeLimitsSetupModel.swift
//  ArgosCore
//
//  Activar o quitar la statusline de Argos que lee los límites de uso de Claude en un
//  servidor (Mac e iPhone/iPad comparten este modelo; ver `ClaudeLimitsInstaller`).
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeLimitsSetupModel {

    enum State: Equatable {
        case checking
        case inactive
        case active
        case failed(String)
    }

    private(set) var state: State = .checking
    private(set) var isWorking = false
    /// Resultado de la última acción, para enseñarlo bajo los botones.
    private(set) var notice: String?

    @ObservationIgnored private let service: any SSHServicing

    init(service: any SSHServicing) {
        self.service = service
    }

    func refresh() async {
        do {
            state = try await service.claudeLimitsInstalled() ? .active : .inactive
        } catch {
            Log.ssh.error("Comprobar la statusline de límites: \(error.userMessage, privacy: .public)")
            state = .failed(error.userMessage)
        }
    }

    func activate() async {
        await run(failure: String(localized: "No se pudo activar")) {
            try await self.service.installClaudeLimits()
            self.state = .active
            self.notice = String(localized: "Activado. Los límites aparecen en cuanto Claude Code refresque su barra de estado (al usarlo); las sesiones ya abiertas lo recogen solas.")
        }
    }

    func deactivate() async {
        await run(failure: String(localized: "No se pudo quitar")) {
            try await self.service.uninstallClaudeLimits()
            self.state = .inactive
            self.notice = String(localized: "Quitado. Claude Code vuelve a usar tu barra de estado anterior.")
        }
    }

    private func run(failure: String, _ action: @escaping () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            Log.ssh.error("\(failure, privacy: .public): \(error.userMessage, privacy: .public)")
            notice = "\(failure): \(error.userMessage)"
        }
    }
}
