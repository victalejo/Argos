//
//  ShellIntegrationModel.swift
//  ArgosCore
//
//  Ajuste «Marcas de prompt (OSC 133)» de un servidor (Mac e iPhone/iPad): lee si el
//  bloque está en sus rc y lo instala o lo quita a petición del usuario.
//

import Foundation
import Observation

@MainActor
@Observable
final class ShellIntegrationModel {
    @ObservationIgnored private let service: any SSHServicing

    /// `nil` mientras no se sabe.
    private(set) var status: ShellIntegrationStatus?
    private(set) var isBusy = false
    var errorMessage: String?

    init(service: any SSHServicing) {
        self.service = service
    }

    /// Aviso tras instalar o quitar.
    static func resultMessage(enabled: Bool) -> String {
        enabled
            ? String(localized: "Marcas de prompt instaladas. Se activan en las shells que abras a partir de ahora.")
            : String(localized: "Marcas de prompt quitadas del servidor (queda copia en .argos-backup).")
    }

    var isEnabled: Bool { status == .installed || status == .outdated }

    func load() async {
        do {
            status = try await ConnectionPriority.background { try await service.shellIntegrationStatus() }
        } catch {
            Log.terminal.notice("No se pudo leer el estado de las marcas de prompt: \(error.userMessage, privacy: .public)")
        }
    }

    /// Instala (o pone al día) o quita el bloque.
    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if enabled {
                try await service.installShellIntegration()
            } else {
                try await service.removeShellIntegration()
            }
            status = try await service.shellIntegrationStatus()
        } catch {
            errorMessage = error.userMessage
            Log.terminal.error("Marcas de prompt: \(error.userMessage, privacy: .public)")
        }
    }
}
