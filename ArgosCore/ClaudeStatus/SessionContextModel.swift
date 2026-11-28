//
//  SessionContextModel.swift
//  ArgosCore
//
//  Interruptor «Contexto de Argos al arrancar Claude» de un servidor y la vista previa de lo
//  que recibiría Claude en un proyecto (Mac e iPhone/iPad comparten este modelo).
//

import Foundation
import Observation

@MainActor
@Observable
final class SessionContextModel {

    enum State: Equatable {
        case checking
        case ready(enabled: Bool)
        case failed(String)
    }

    private(set) var state: State = .checking
    private(set) var isWorking = false
    /// Resultado o error de la última acción.
    private(set) var notice: String?
    private(set) var preview: SessionContextPreview?
    private(set) var isPreviewing = false

    @ObservationIgnored private let service: any SSHServicing

    init(service: any SSHServicing) {
        self.service = service
    }

    var isEnabled: Bool { state == .ready(enabled: true) }

    func refresh() async {
        do {
            state = .ready(enabled: try await service.sessionContextEnabled())
        } catch {
            Log.ssh.error("Comprobar el contexto de Claude: \(error.userMessage, privacy: .public)")
            state = .failed(error.userMessage)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isWorking, state != .ready(enabled: enabled) else { return }
        isWorking = true
        notice = nil
        preview = nil
        defer { isWorking = false }
        do {
            try await service.setSessionContextEnabled(enabled)
            state = .ready(enabled: enabled)
            notice = enabled
                ? String(localized: "Activado. Claude lo recibe al abrirse, reanudarse, limpiar (/clear) o compactar.")
                : String(localized: "Desactivado. Claude ya no recibe el resumen de Argos en este servidor.")
        } catch {
            Log.ssh.error("Cambiar el contexto de Claude: \(error.userMessage, privacy: .public)")
            notice = String(localized: "No se pudo cambiar: \(error.userMessage)")
            await refresh()
        }
    }

    func loadPreview(projectPath: String) async {
        guard !isPreviewing else { return }
        isPreviewing = true
        notice = nil
        defer { isPreviewing = false }
        do {
            preview = try await service.previewSessionContext(projectPath: projectPath)
        } catch {
            Log.ssh.error("Vista previa del contexto de Claude: \(error.userMessage, privacy: .public)")
            preview = nil
            notice = String(localized: "No se pudo ejecutar: \(error.userMessage)")
        }
    }
}
