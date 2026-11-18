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
//   - Con el Mac dormido nadie toca la red; al despertar se comprueba todo enseguida.
//

import Foundation
@preconcurrency import Citadel

extension SSHService {

    /// Intervalo del heartbeat: más corto que los timeouts típicos de NAT/firewall
    /// (~60-120s) para que la conexión idle no se corte sin que la app lo sepa.
    static let heartbeatInterval: Duration = .seconds(30)
    /// Tope de un latido. Una conexión medio abierta (cambio de red, NAT que la olvidó)
    /// no falla: se queda esperando hasta el timeout de TCP, que son minutos. Es holgado
    /// a propósito: por la conexión compartida también van subidas, y con la línea
    /// cargada la respuesta puede tardar; cerrarla por un retraso corto abortaría trabajo
    /// sano. Ya no incluye esperar turno (el latido tiene canal propio).
    static let heartbeatTimeout: Duration = .seconds(30)
    /// Cada cuánto se sondea cada conexión dedicada y su plazo.
    static let linkCheckInterval: Duration = .seconds(30)
    static let linkCheckTimeout: Duration = .seconds(20)
    /// Plazo de `checkConnectionNow()` (al volver a primer plano): corto, el usuario espera.
    static let quickCheckTimeout: Duration = .seconds(5)

    // MARK: - Conexión compartida

    /// Arranca el heartbeat de la conexión actual.
    ///
    /// `beatImmediately`: al despertar del reposo conviene comprobar la conexión YA (la
    /// red pudo cambiar o el NAT olvidarla) en vez de esperar al primer intervalo.
    func startHeartbeat(beatImmediately: Bool = false) {
        guard !heartbeatSuspended else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var skipSleep = beatImmediately
            while !Task.isCancelled {
                if !skipSleep {
                    try? await Task.sleep(for: SSHService.heartbeatInterval)
                }
                skipSleep = false
                guard let self else { return }
                let alive = await self.beat()
                if !alive { return }
            }
        }
    }

    /// Un latido. Devuelve `false` si la conexión está caída y la limpia, forzando una
    /// reconexión en la próxima operación.
    private func beat() async -> Bool {
        // Si el reposo llegó con un latido ya en marcha, no tocar la red.
        if heartbeatSuspended { return true }
        guard let probed = client, probed.isConnected else { return false }
        if await probeShared(within: Self.heartbeatTimeout) { return true }
        // Cancelado (reposo, desconexión) no es «caída»: no se toca la conexión.
        if Task.isCancelled || heartbeatSuspended { return true }
        Log.ssh.notice("Heartbeat falló en \(self.configuration.host, privacy: .public); se marca la conexión como caída.")
        discardShared(probed)
        return false
    }

    /// Comprueba AHORA la conexión compartida con un plazo corto y, si no responde, la
    /// descarta (la próxima operación reconecta) y revisa también las dedicadas. Pensado
    /// para volver a primer plano en iOS. Devuelve `true` si había conexión y respondió.
    @discardableResult
    func checkConnectionNow(timeout: Duration) async -> Bool {
        guard let probed = client, probed.isConnected else {
            checkAllLinksSoon()
            return false
        }
        if await probeShared(within: timeout) { return true }
        if Task.isCancelled { return false }
        Log.ssh.notice("La conexión con \(self.configuration.host, privacy: .public) no respondió en \(timeout.components.seconds) s; se descarta.")
        discardShared(probed)
        return false
    }

    /// Comando trivial por el canal reservado del latido (sin turno de `ChannelGate`).
    private func probeShared(within timeout: Duration) async -> Bool {
        await Deadline.succeeds(within: timeout) { [weak self] in
            await self?.probeSharedOnce() ?? false
        }
    }

    private func probeSharedOnce() async -> Bool {
        guard let client, client.isConnected else { return false }
        return (try? await captureOnce(client, command: "true")) != nil
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

    func startLinkMonitor(_ id: UUID) {
        linkMonitors[id]?.cancel()
        linkMonitors[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SSHService.linkCheckInterval)
                guard let self, !Task.isCancelled else { return }
                let keepWatching = await self.checkLink(id)
                if !keepWatching { return }
            }
        }
    }

    func stopLinkMonitor(_ id: UUID) {
        linkMonitors.removeValue(forKey: id)?.cancel()
    }

    func stopAllLinkMonitors() {
        for monitor in linkMonitors.values { monitor.cancel() }
        linkMonitors.removeAll()
    }

    /// Revisa todas las conexiones vigiladas a la vez, sin bloquear a quien llama.
    func checkAllLinksSoon() {
        let ids = Array(dedicatedClients.keys) + Array(portForwards.keys)
        guard !ids.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { _ = await self.checkLink(id) }
                }
            }
        }
    }

    /// Una comprobación. Devuelve si hay que seguir vigilando esa conexión.
    private func checkLink(_ id: UUID) async -> Bool {
        guard let watched = linkClient(id) else { return false }
        if heartbeatSuspended { return true }
        if watched.isConnected {
            let alive = await Deadline.succeeds(within: Self.linkCheckTimeout) { [weak self] in
                await self?.probeLinkOnce(id, expected: watched) ?? false
            }
            if alive || Task.isCancelled || heartbeatSuspended { return true }
        }
        // Entretanto pudo cerrarse o sustituirse (túnel reabierto con el mismo id).
        guard linkClient(id) === watched else { return false }
        Log.ssh.notice("Una conexión dedicada con \(self.configuration.host, privacy: .public) no responde; se cierra para que se reconecte.")
        lostLinks.insert(id)
        try? await watched.close()
        if portForwards[id] != nil {
            // Túnel: se reabre en el mismo puerto local (como trabajo de fondo).
            lostLinks.remove(id)
            await ConnectionPriority.background { await reopenBrokenPortForwards() }
        }
        return false
    }

    private func probeLinkOnce(_ id: UUID, expected: SSHClient) async -> Bool {
        guard let client = linkClient(id), client === expected, client.isConnected else { return false }
        return (try? await captureOnce(client, command: "true")) != nil
    }
}
