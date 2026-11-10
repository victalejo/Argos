//
//  SSHPortForwarding.swift
//  ArgosCore
//
//  Túneles de puertos del servidor al dispositivo. Cada túnel usa su PROPIA conexión
//  SSH (no la compartida de comandos cortos): así no compite por canales y, al
//  pararlo, cerrar esa conexión corta de golpe todas sus conexiones en curso.
//

import Foundation
import NIOCore
@preconcurrency import Citadel

/// Estado interno de un túnel (vive en el actor).
struct PortForwardRuntime: Sendable {
    let info: ActivePortForward
    let connection: ForwardConnection
    let listener: Channel
}

extension SSHService {

    /// Puertos TCP en escucha en el servidor.
    func listeningPorts() async throws -> [ListeningPort] {
        let client = try await connectedClient()
        let result = try await capture(client, command: ListeningPortParser.command)
        return ListeningPortParser.parse(result.stdout)
    }

    /// Abre un túnel `localhost:<local>` → `targetHost:remotePort` del servidor. Intenta
    /// usar el mismo número de puerto en el dispositivo; si está ocupado, otro libre.
    func startPortForward(
        remotePort: Int,
        targetHost: String,
        preferredLocalPort: Int
    ) async throws -> ActivePortForward {
        guard (1...65535).contains(remotePort) else { throw PortForwardError.invalidPort(remotePort) }
        if portForwards.values.contains(where: { $0.info.remotePort == remotePort }) {
            throw PortForwardError.alreadyForwarded(remotePort)
        }
        return try await openForward(
            id: UUID(), remotePort: remotePort, targetHost: targetHost, preferredLocalPort: preferredLocalPort
        )
    }

    func stopPortForward(id: UUID) async {
        guard let runtime = portForwards.removeValue(forKey: id) else { return }
        await close(runtime)
        Log.ssh.notice("Túnel cerrado: puerto \(runtime.info.remotePort)")
    }

    func stopAllPortForwards() async {
        let runtimes = Array(portForwards.values)
        portForwards.removeAll()
        for runtime in runtimes { await close(runtime) }
    }

    /// Túneles activos. Si la conexión SSH de alguno se cayó (red, reposo), lo reabre en
    /// el MISMO puerto local para que las pestañas del navegador sigan funcionando.
    func activePortForwards() async -> [ActivePortForward] {
        for runtime in portForwards.values where !runtime.connection.client.isConnected {
            await reopen(runtime)
        }
        return portForwards.values.map(\.info).sorted { $0.remotePort < $1.remotePort }
    }

    // MARK: - Privado

    private func openForward(
        id: UUID,
        remotePort: Int,
        targetHost: String,
        preferredLocalPort: Int
    ) async throws -> ActivePortForward {
        let client = try await openClient()
        let connection = ForwardConnection(client)
        do {
            let (listener, localPort) = try await LocalPortForwarder.listen(
                connection: connection, targetHost: targetHost,
                remotePort: remotePort, preferredLocalPort: preferredLocalPort
            )
            let info = ActivePortForward(id: id, remotePort: remotePort, targetHost: targetHost, localPort: localPort)
            portForwards[id] = PortForwardRuntime(info: info, connection: connection, listener: listener)
            Log.ssh.notice("Túnel abierto: localhost:\(localPort) → \(targetHost, privacy: .public):\(remotePort)")
            return info
        } catch {
            try? await client.close()
            throw error
        }
    }

    private func reopen(_ runtime: PortForwardRuntime) async {
        let info = runtime.info
        portForwards.removeValue(forKey: info.id)
        await close(runtime)
        do {
            _ = try await openForward(
                id: info.id, remotePort: info.remotePort,
                targetHost: info.targetHost, preferredLocalPort: info.localPort
            )
        } catch {
            Log.ssh.error("No se pudo reabrir el túnel del puerto \(info.remotePort): \(error.userMessage, privacy: .public)")
        }
    }

    private func close(_ runtime: PortForwardRuntime) async {
        try? await runtime.listener.close()
        try? await runtime.connection.client.close()
    }
}
