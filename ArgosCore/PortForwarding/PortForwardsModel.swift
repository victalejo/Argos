//
//  PortForwardsModel.swift
//  ArgosCore
//
//  Estado de la hoja «Puertos» de un servidor (Mac e iPhone/iPad): qué puertos escuchan
//  en el servidor y cuáles se están reenviando a este dispositivo. Los túneles viven en
//  el actor `SSHService`: este modelo es efímero y se puede recrear sin cerrarlos.
//

import Foundation
import Observation

@MainActor
@Observable
final class PortForwardsModel {
    private let service: any SSHServicing

    private(set) var listening: [ListeningPort] = []
    private(set) var forwards: [ActivePortForward] = []
    private(set) var hasLoaded = false
    private(set) var listError: String?
    /// Puertos con una operación en curso (abrir/cerrar).
    private(set) var busyPorts: Set<Int> = []
    /// Último fallo de una operación; la UI lo muestra y lo borra.
    var errorMessage: String?
    /// Mostrar también puertos de sistema (DNS local, sshd…).
    var showsSystemPorts = false

    /// Minutos sin conexiones tras los que se cierra un túnel (0 = nunca). Preferencia del
    /// dispositivo; el vigilante del servicio la lee en cada pasada.
    var idleMinutes: Int = PortForwardIdlePolicy.limitMinutes {
        didSet { PortForwardIdlePolicy.limitMinutes = idleMinutes }
    }

    static let pollInterval: Duration = .seconds(5)

    init(service: any SSHServicing) {
        self.service = service
    }

    // MARK: - Derivados

    /// Puertos detectados que se ofrecen (los de sistema solo si se piden).
    var visiblePorts: [ListeningPort] {
        showsSystemPorts ? listening : listening.filter(\.isLikelyDevServer)
    }

    var hiddenSystemPortCount: Int { listening.count - listening.filter(\.isLikelyDevServer).count }

    func forward(forRemotePort port: Int) -> ActivePortForward? {
        forwards.first { $0.remotePort == port }
    }

    /// Valida un puerto escrito a mano (lógica pura).
    nonisolated static func parsePort(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }

    // MARK: - Carga

    func refresh() async {
        forwards = await service.activePortForwards()
        do {
            listening = try await service.listeningPorts()
            listError = nil
        } catch {
            listError = error.userMessage
        }
        hasLoaded = true
    }

    /// Refresco mientras la hoja está visible (cancelado por `.task`).
    func pollWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    // MARK: - Operaciones

    /// Abre el túnel de un puerto detectado. Devuelve el túnel (para abrirlo en el navegador).
    @discardableResult
    func start(_ port: ListeningPort) async -> ActivePortForward? {
        await start(remotePort: port.port, targetHost: port.targetHost)
    }

    /// Abre el túnel de un puerto escrito a mano (p. ej. uno que aún no escucha).
    @discardableResult
    func startManual(_ text: String) async -> ActivePortForward? {
        guard let port = Self.parsePort(text) else {
            errorMessage = "Escribe un puerto entre 1 y 65535."
            return nil
        }
        let target = listening.first { $0.port == port }?.targetHost ?? "localhost"
        return await start(remotePort: port, targetHost: target)
    }

    func stop(_ forward: ActivePortForward) async {
        busyPorts.insert(forward.remotePort)
        await service.stopPortForward(id: forward.id)
        busyPorts.remove(forward.remotePort)
        forwards = await service.activePortForwards()
    }

    private func start(remotePort: Int, targetHost: String) async -> ActivePortForward? {
        if let existing = forward(forRemotePort: remotePort) { return existing }
        guard !busyPorts.contains(remotePort) else { return nil }
        busyPorts.insert(remotePort)
        defer { busyPorts.remove(remotePort) }
        do {
            let forward = try await service.startPortForward(
                remotePort: remotePort, targetHost: targetHost, preferredLocalPort: remotePort
            )
            forwards = await service.activePortForwards()
            return forward
        } catch {
            errorMessage = error.userMessage
            Log.ssh.error("Abrir túnel \(remotePort): \(error.userMessage, privacy: .public)")
            return nil
        }
    }
}
