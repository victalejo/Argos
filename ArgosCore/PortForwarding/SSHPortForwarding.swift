//
//  SSHPortForwarding.swift
//  ArgosCore
//
//  Túneles de puertos del servidor al dispositivo. Cada túnel usa su PROPIA conexión SSH
//  (no la compartida de comandos cortos): así no compite por canales y, al pararlo, cerrar
//  esa conexión corta de golpe todas sus conexiones en curso.
//
//  Mientras haya túneles, un vigilante (cada `watchInterval`) cierra los que llevan el
//  límite de `PortForwardIdlePolicy` sin conexiones, reabre los caídos y mantiene al día
//  `~/.config/argos/forwards/<dispositivo>.tsv` en el servidor para la skill de Claude.
//

import Foundation
import NIOCore
@preconcurrency import Citadel

/// Estado interno de un túnel (vive en el actor).
struct PortForwardRuntime: Sendable {
    let info: ActivePortForward
    let connection: ForwardConnection
    let listener: Channel
    let activity: PortForwardActivity
}

extension SSHService {

    /// Cada cuánto revisa el vigilante.
    static let portForwardWatchInterval: Duration = .seconds(30)

    /// Puertos TCP en escucha en el servidor (y, la primera vez, instala `argos-ports`).
    func listeningPorts() async throws -> [ListeningPort] {
        let client = try await connectedClient()
        await ensurePortsTool()
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
        let info = try await openForward(
            id: UUID(), remotePort: remotePort, targetHost: targetHost, preferredLocalPort: preferredLocalPort
        )
        await ensurePortsTool()
        await publishPortForwards()
        startPortForwardWatcher()
        return info
    }

    func stopPortForward(id: UUID) async {
        guard let runtime = portForwards.removeValue(forKey: id) else { return }
        await close(runtime)
        Log.ssh.notice("Túnel cerrado: puerto \(runtime.info.remotePort)")
        await publishPortForwards()
    }

    /// Cierra todos (al desconectar). Borra el archivo del servidor si la conexión sigue viva.
    func stopAllPortForwards() async {
        portForwardWatcher?.cancel()
        portForwardWatcher = nil
        let runtimes = Array(portForwards.values)
        portForwards.removeAll()
        for runtime in runtimes { await close(runtime) }
        if !runtimes.isEmpty {
            await captureIfConnected(PortForwardServerFiles.unpublishCommand(deviceID: PortForwardDevice.id))
        }
        portForwardsPublishedAt = nil
    }

    /// Túneles activos. Si la conexión SSH de alguno se cayó (red, reposo), lo reabre en el
    /// MISMO puerto local para que las pestañas del navegador sigan funcionando.
    func activePortForwards() async -> [ActivePortForward] {
        var changed = false
        for runtime in portForwards.values where !runtime.connection.client.isConnected {
            await reopen(runtime)
            changed = true
        }
        if changed { await publishPortForwards() }
        return portForwards.values.map(\.info).sorted { $0.remotePort < $1.remotePort }
    }

    // MARK: - Solicitudes de Claude

    /// Solicitudes pendientes (`argos-ports open`). Las caducadas se borran y no se devuelven.
    func pendingPortForwardRequests() async throws -> [PortForwardRequest] {
        let client = try await connectedClient()
        let result = try await capture(client, command: PortForwardServerFiles.listRequestsCommand)
        return PortForwardRequestParser.parse(result.stdout)
    }

    /// Retira una solicitud (aceptada o rechazada). Best-effort.
    func dismissPortForwardRequest(port: Int) async {
        await captureIfConnected(PortForwardServerFiles.dismissRequestCommand(port: port))
    }

    // MARK: - Vigilante

    private func startPortForwardWatcher() {
        guard portForwardWatcher == nil else { return }
        portForwardWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SSHService.portForwardWatchInterval)
                guard let self, !Task.isCancelled else { return }
                let keepGoing = await self.watchPortForwards()
                if !keepGoing { return }
            }
        }
    }

    /// Una pasada: cierra los inactivos, reabre los caídos y renueva el archivo del servidor.
    /// Devuelve `false` cuando ya no quedan túneles (el vigilante termina).
    private func watchPortForwards(now: Date = Date()) async -> Bool {
        let limit = PortForwardIdlePolicy.limitMinutes
        var changed = false
        for runtime in portForwards.values {
            let (active, last) = runtime.activity.snapshot
            if PortForwardIdlePolicy.shouldClose(activeConnections: active, lastActivity: last,
                                                 now: now, limitMinutes: limit) {
                portForwards.removeValue(forKey: runtime.info.id)
                await close(runtime)
                Log.ssh.notice("Túnel del puerto \(runtime.info.remotePort) cerrado tras \(limit) min sin uso")
                changed = true
            }
        }
        _ = await activePortForwards()   // reabre caídos (y publica si cambió)
        let stale = portForwardsPublishedAt.map { now.timeIntervalSince($0) >= PortForwardServerFiles.refreshInterval } ?? true
        if changed || stale { await publishPortForwards() }
        if portForwards.isEmpty {
            portForwardWatcher = nil
            return false
        }
        return true
    }

    // MARK: - Archivos del servidor (skill de Claude)

    /// Escribe (o borra, si no hay túneles) el archivo de este dispositivo. Best-effort.
    private func publishPortForwards() async {
        let forwards = portForwards.values.map(\.info)
        let command = forwards.isEmpty
            ? PortForwardServerFiles.unpublishCommand(deviceID: PortForwardDevice.id)
            : PortForwardServerFiles.publishCommand(
                deviceID: PortForwardDevice.id, deviceName: PortForwardDevice.name, forwards: forwards
            )
        if await captureIfConnected(command) {
            portForwardsPublishedAt = forwards.isEmpty ? nil : Date()
        }
    }

    /// Instala (una vez por conexión) el script `argos-ports` y la skill de Claude.
    private func ensurePortsTool() async {
        guard !portsToolChecked else { return }
        portsToolChecked = true
        if !(await captureIfConnected(PortForwardServerFiles.installCommand)) {
            portsToolChecked = false
        }
    }

    // MARK: - Túneles

    private func openForward(
        id: UUID,
        remotePort: Int,
        targetHost: String,
        preferredLocalPort: Int
    ) async throws -> ActivePortForward {
        let client = try await openClient()
        let connection = ForwardConnection(client)
        let activity = PortForwardActivity()
        do {
            let (listener, localPort) = try await LocalPortForwarder.listen(
                connection: connection, activity: activity, targetHost: targetHost,
                remotePort: remotePort, preferredLocalPort: preferredLocalPort
            )
            let info = ActivePortForward(id: id, remotePort: remotePort, targetHost: targetHost, localPort: localPort)
            portForwards[id] = PortForwardRuntime(info: info, connection: connection, listener: listener, activity: activity)
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
