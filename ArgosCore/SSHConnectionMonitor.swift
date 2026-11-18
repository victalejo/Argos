//
//  SSHConnectionMonitor.swift
//  Argos
//
//  Latidos de `SSHService`:
//
//   - Conexión compartida: un comando trivial cada `heartbeatInterval` evita que NAT o
//     el cortafuegos corten la conexión ociosa y detecta pronto una caída (si no, el
//     indicador seguiría «verde» hasta el próximo uso). Va por un canal reservado FUERA
//     del cupo de `ChannelGate`: con la cola llena, esperar turno no es «conexión muerta».
//   - Conexiones dedicadas (terminales, agentes) y túneles: un vigilante por conexión.
//     Si deja de responder se cierra, y su dueño reconecta con su propio backoff.
//   - Prudencia (ver `LinkLiveness`): un canal rechazado prueba que el servidor está vivo;
//     solo varios sondeos SIN respuesta seguidos cierran; y una conexión con tráfico
//     reciente ni se sondea.
//   - Con el Mac dormido nadie toca la red; al despertar se comprueba todo enseguida.
//

import Foundation
@preconcurrency import Citadel

extension SSHService {

    /// Plazo de `checkConnectionNow()` (al volver a primer plano): corto, el usuario espera.
    static let quickCheckTimeout: Duration = .seconds(5)

    /// Cambia el ritmo y los umbrales de los vigilantes (los tests lo acortan).
    func setMonitorPolicy(_ policy: ConnectionMonitorPolicy) {
        monitorPolicy = policy
    }

    // MARK: - Conexión compartida

    /// Arranca el heartbeat de la conexión actual.
    ///
    /// `beatImmediately`: al despertar del reposo conviene comprobar la conexión YA (la
    /// red pudo cambiar o el NAT olvidarla) en vez de esperar al primer intervalo.
    func startHeartbeat(beatImmediately: Bool = false) {
        guard !heartbeatSuspended else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var liveness = LinkLiveness()
            var skipSleep = beatImmediately
            while !Task.isCancelled {
                if !skipSleep {
                    guard let wait = await self?.heartbeatWait(after: liveness) else { return }
                    try? await Task.sleep(for: wait)
                }
                skipSleep = false
                guard let self, !Task.isCancelled else { return }
                guard let next = await self.beat(liveness) else { return }
                liveness = next
            }
        }
    }

    private func heartbeatWait(after liveness: LinkLiveness) -> Duration {
        liveness.consecutiveFailures > 0 ? monitorPolicy.retryInterval : monitorPolicy.heartbeatInterval
    }

    /// Un latido. Devuelve el nuevo recuento, o `nil` si la conexión se dio por caída (y se
    /// limpió: la próxima operación reconecta).
    private func beat(_ liveness: LinkLiveness) async -> LinkLiveness? {
        // Si el reposo llegó con un latido ya en marcha, no tocar la red.
        if heartbeatSuspended { return liveness }
        guard let probed = client, probed.isConnected else { return nil }
        let policy = monitorPolicy
        // Con tráfico reciente la conexión está viva y el NAT, despierto.
        if sharedActivity.isRecent(within: policy.heartbeatInterval) { return LinkLiveness() }
        let outcome = await probeShared(within: policy.heartbeatTimeout)
        // Cancelado (reposo, desconexión) no es «caída»: no se toca la conexión.
        if Task.isCancelled || heartbeatSuspended { return liveness }
        let next = liveness.recording(outcome, threshold: policy.sharedFailuresToDiscard)
        guard next.isDead(threshold: policy.sharedFailuresToDiscard) else {
            if outcome == .unresponsive {
                Log.ssh.notice("Latido sin respuesta en \(self.configuration.host, privacy: .public) (\(next.consecutiveFailures) seguidos)")
            }
            return next
        }
        Log.ssh.notice("Heartbeat falló en \(self.configuration.host, privacy: .public); se marca la conexión como caída.")
        discardShared(probed)
        return nil
    }

    /// Comprueba AHORA la conexión compartida con un plazo corto y, si no responde, la
    /// descarta (la próxima operación reconecta) y revisa también las dedicadas. Pensado
    /// para volver a primer plano en iOS. Devuelve `true` si había conexión y respondió
    /// (un canal rechazado también es respuesta: el servidor está vivo).
    @discardableResult
    func checkConnectionNow(timeout: Duration) async -> Bool {
        guard let probed = client, probed.isConnected else {
            checkAllLinksSoon()
            return false
        }
        switch await probeShared(within: timeout) {
        case .alive, .rejected:
            return true
        case .unresponsive, .broken:
            if Task.isCancelled { return false }
            Log.ssh.notice("La conexión con \(self.configuration.host, privacy: .public) no respondió en \(timeout.components.seconds) s; se descarta.")
            discardShared(probed)
            return false
        }
    }

    /// Comando trivial por el canal reservado del latido (sin turno de `ChannelGate`).
    private func probeShared(within timeout: Duration) async -> ProbeOutcome {
        sharedProbeCount += 1
        do {
            try await Deadline.value(
                within: timeout, timeoutError: { SSHConnectionError.commandTimedOut(timeout) }
            ) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.probeSharedOnce()
            }
            return .alive
        } catch {
            return ProbeOutcome.from(error: error)
        }
    }

    private func probeSharedOnce() async throws {
        guard let client, client.isConnected else { throw SSHConnectionError.notConnected }
        _ = try await captureOnce(client, command: "true")
    }

    /// Da por caída la compartida (si sigue siendo la misma) y revisa enseguida las
    /// dedicadas: si se cayó la red, lo normal es que hayan caído todas.
    private func discardShared(_ probed: SSHClient) {
        if client === probed { replaceSharedClient(with: nil) }
        checkAllLinksSoon()
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Pausa el keep-alive (compartida y dedicadas) sin cerrar nada: con el Mac dormido no
    /// se ejecuta ningún comando proactivo. Las acciones explícitas siguen conectando.
    func suspendHeartbeat() async {
        heartbeatSuspended = true
        stopHeartbeat()
    }

    /// Reanuda el keep-alive tras el reposo y comprueba YA la compartida y TODAS las
    /// dedicadas (también los terminales que figuran como conectados): las que murieron
    /// durante el reposo se cierran y sus dueños reconectan.
    func resumeHeartbeat() async {
        heartbeatSuspended = false
        if let client, client.isConnected {
            startHeartbeat(beatImmediately: true)
        }
        checkAllLinksSoon()
    }

    // MARK: - Conexiones dedicadas y túneles

    /// Conexión vigilada: dedicada (terminal, agente) o de un túnel.
    func linkClient(_ id: UUID) -> SSHClient? {
        dedicatedClients[id] ?? portForwards[id]?.connection.client
    }

    /// ¿Tiene vigilante en marcha? (para los tests).
    func hasLinkMonitor(_ id: UUID) -> Bool {
        linkMonitors[id] != nil
    }

    /// ¿Sigue abierta la conexión vigilada? (para los tests).
    func isLinkConnected(_ id: UUID) -> Bool {
        linkClient(id)?.isConnected ?? false
    }

    /// Conexiones dedicadas abiertas ahora (para los tests).
    var dedicatedLinkIDs: [UUID] { Array(dedicatedClients.keys) }

    func startLinkMonitor(_ id: UUID) {
        linkMonitors[id]?.cancel()
        linkMonitors[id] = Task { [weak self] in
            var liveness = LinkLiveness()
            while !Task.isCancelled {
                guard let wait = await self?.linkWait(after: liveness) else { return }
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                guard let next = await self.checkLink(id, liveness: liveness) else { return }
                liveness = next
            }
        }
    }

    private func linkWait(after liveness: LinkLiveness) -> Duration {
        liveness.consecutiveFailures > 0 ? monitorPolicy.retryInterval : monitorPolicy.linkInterval
    }

    func stopLinkMonitor(_ id: UUID) {
        linkMonitors.removeValue(forKey: id)?.cancel()
    }

    func stopAllLinkMonitors() {
        for monitor in linkMonitors.values { monitor.cancel() }
        linkMonitors.removeAll()
    }

    /// Revisa todas las conexiones vigiladas a la vez, sin bloquear a quien llama. Cada una
    /// se confirma con sondeos seguidos (no basta un fallo para cerrarla).
    func checkAllLinksSoon() {
        let ids = Array(dedicatedClients.keys) + Array(portForwards.keys)
        guard !ids.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { await self.confirmLink(id) }
                }
            }
        }
    }

    /// Sondeos seguidos hasta saber si la conexión vive (o cerrarla).
    private func confirmLink(_ id: UUID) async {
        var liveness = LinkLiveness()
        while let next = await checkLink(id, liveness: liveness), next.consecutiveFailures > 0 {
            liveness = next
            try? await Task.sleep(for: monitorPolicy.retryInterval)
        }
    }

    /// Una comprobación. Devuelve el nuevo recuento, o `nil` si ya no hay que vigilarla
    /// (se cerró, se sustituyó o se dio por perdida).
    private func checkLink(_ id: UUID, liveness: LinkLiveness) async -> LinkLiveness? {
        guard let watched = linkClient(id) else { return nil }
        if heartbeatSuspended { return liveness }
        let policy = monitorPolicy
        if linkHadRecentTraffic(id, within: policy.linkInterval) { return LinkLiveness() }
        let outcome = await probeLink(id, watched, within: policy.linkTimeout)
        if Task.isCancelled || heartbeatSuspended { return liveness }
        let next = liveness.recording(outcome, threshold: policy.linkFailuresToClose)
        guard next.isDead(threshold: policy.linkFailuresToClose) else { return next }
        // Entretanto pudo cerrarse o sustituirse (túnel reabierto con el mismo id).
        guard linkClient(id) === watched else { return nil }
        await handleLostLink(id, watched)
        return nil
    }

    /// Un terminal con salida o un túnel con conexiones recientes están vivos.
    private func linkHadRecentTraffic(_ id: UUID, within window: Duration) -> Bool {
        if let activity = linkActivities[id], activity.isRecent(within: window) { return true }
        if let forward = portForwards[id] {
            let seconds = Double(window.components.seconds)
            return Date().timeIntervalSince(forward.activity.snapshot.lastActivity) < seconds
        }
        return false
    }

    private func probeLink(_ id: UUID, _ watched: SSHClient, within timeout: Duration) async -> ProbeOutcome {
        guard watched.isConnected else { return .broken }
        linkProbeCount += 1
        let expected = ObjectIdentifier(watched)
        do {
            try await Deadline.value(
                within: timeout, timeoutError: { SSHConnectionError.commandTimedOut(timeout) }
            ) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.probeLinkOnce(id, expected: expected)
            }
            return .alive
        } catch {
            return ProbeOutcome.from(error: error)
        }
    }

    private func probeLinkOnce(_ id: UUID, expected: ObjectIdentifier) async throws {
        guard let client = linkClient(id), ObjectIdentifier(client) == expected, client.isConnected else {
            throw SSHConnectionError.notConnected
        }
        _ = try await captureOnce(client, command: "true")
    }

    /// Cierra una conexión que dejó de responder. Una dedicada termina con
    /// `connectionLost` (su dueño reconecta); un túnel se reabre en el mismo puerto local.
    func handleLostLink(_ id: UUID, _ watched: SSHClient) async {
        Log.ssh.notice("Una conexión dedicada con \(self.configuration.host, privacy: .public) no responde; se cierra para que se reconecte.")
        let isForward = portForwards[id] != nil
        if !isForward { lostLinks.insert(id) }
        try? await watched.close()
        guard isForward else { return }
        // En una tarea propia: la reapertura cierra el túnel viejo y con él este vigilante
        // (cancelar la tarea en curso dejaría cancelada también la reapertura).
        Task { [weak self] in
            _ = await ConnectionPriority.background { await self?.reopenBrokenPortForwards() }
        }
    }

    /// Da por perdida una conexión vigilada como si su vigilante hubiera agotado los
    /// sondeos (para los tests: no hace falta tumbar la red).
    func simulateLinkLoss(_ id: UUID) async {
        guard let watched = linkClient(id) else { return }
        await handleLostLink(id, watched)
    }
}
