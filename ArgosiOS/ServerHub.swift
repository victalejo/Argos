//
//  ServerHub.swift
//  ArgosiOS
//
//  Estado compartido de la app de iPhone/iPad: los servidores (`ServerStore`), un
//  `SessionsViewModel` por servidor (lista de proyectos y sesiones) y los terminales
//  vivos. Reutilizar el view model mantiene UNA conexión SSH por servidor; reutilizar
//  el controlador hace que volver a un terminal sea instantáneo.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ServerHub {
    let store: ServerStore
    /// Ignorado por Observation: se rellena perezosamente desde las vistas, y escribir
    /// estado observado durante `body` provoca invalidaciones en bucle.
    @ObservationIgnored private var viewModels: [Server.ID: SessionsViewModel] = [:]
    @ObservationIgnored private var terminals: [SessionHandle: TouchTerminalController] = [:]
    @ObservationIgnored private var detachTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var agents: [String: (server: Server.ID, session: PersistentAgentSession)] = [:]
    /// Agentes que estaban enganchados al pasar a segundo plano (se reenganchan al volver).
    @ObservationIgnored private var suspendedAgents: [PersistentAgentSession] = []

    /// Sincronización de servidores y huellas con el Mac y otros iPhone/iPad (iCloud).
    @ObservationIgnored private(set) var cloudSync: CloudServerSync?

    init(store: ServerStore = ServerStore(), syncWithICloud: Bool = true) {
        self.store = store
        guard syncWithICloud else { return }
        let sync = CloudServerSync(store: store)
        // Borrado en otro dispositivo: limpiar lo de este (conexiones, secretos, clave).
        sync.onRemoteRemoval = { [weak self] server in self?.forgetLocally(server) }
        sync.start()
        cloudSync = sync
    }

    // MARK: - Servidores

    /// Guarda un servidor nuevo o editado, con su secreto (contraseña o passphrase).
    func save(_ server: Server, secret: String?, isNew: Bool) throws {
        switch server.authMethod {
        case .password:
            try KeychainStore.setPassword(secret, for: server.id)
            KeychainStore.deletePassphrase(for: server.id)
            ImportedKeyStore.remove(for: server.id)
        case .key:
            try KeychainStore.setPassphrase(server.requiresPassphrase ? secret : nil, for: server.id)
            KeychainStore.deletePassword(for: server.id)
        }
        if isNew { store.add(server) } else { store.update(server) }
        disconnect(server.id)
    }

    /// Servidor del QR del Mac: guarda su clave dedicada y fija la huella de host key que
    /// verificó el Mac. Si ese servidor ya está (llegó por iCloud), le pone la clave en vez
    /// de duplicarlo.
    @discardableResult
    func importTransfer(_ transfer: ServerTransfer) throws -> Server {
        guard !transfer.conflictsWithTrustedHostKey() else {
            throw ServerTransfer.HostKeyConflictError(endpoint: "\(transfer.host):\(transfer.port)")
        }
        let existing = transfer.matchingServer(in: store.servers) { ImportedKeyStore.needsImport($0) }
        let id = existing?.id ?? UUID()
        let pem = Data(try transfer.privateKeyPEM().utf8)
        let path = try ImportedKeyStore.store(pem, for: id)
        var server = existing ?? Server(
            id: id,
            name: transfer.name,
            host: transfer.host,
            port: transfer.port,
            username: transfer.username,
            authMethod: .key,
            privateKeyPath: path
        )
        server.privateKeyPath = path
        server.requiresPassphrase = false // la clave dedicada del QR no lleva passphrase
        do {
            try save(server, secret: nil, isNew: existing == nil)
        } catch {
            ImportedKeyStore.remove(for: id) // el servidor no tenía clave antes del QR
            throw error
        }
        if let fingerprint = transfer.hostKeyFingerprint {
            TOFUHostKeyValidator.trustIfUnknown(fingerprint: fingerprint, host: transfer.host, port: transfer.port)
        }
        return server
    }

    /// Borra el servidor con TODO lo suyo: secretos, clave importada y conexiones.
    func remove(_ server: Server) {
        forgetLocally(server)
        store.remove(server)
    }

    /// Lo propio de este dispositivo de un servidor que ya no está.
    private func forgetLocally(_ server: Server) {
        disconnect(server.id)
        KeychainStore.deletePassword(for: server.id)
        KeychainStore.deletePassphrase(for: server.id)
        ImportedKeyStore.remove(for: server.id)
    }

    // MARK: - Sesiones

    func viewModel(for server: Server) -> SessionsViewModel {
        if let existing = viewModels[server.id] { return existing }
        let viewModel = SessionsViewModel(service: server.makeService())
        viewModels[server.id] = viewModel
        return viewModel
    }

    /// Olvida la huella del servidor y reconecta (tras una reinstalación legítima).
    func forgetHostKey(of server: Server) {
        TOFUHostKeyValidator.forget(host: server.host, port: server.port)
        disconnect(server.id)
    }

    // MARK: - Terminales

    func terminal(for server: Server, sessionName: String) -> TouchTerminalController {
        let handle = SessionHandle(serverID: server.id, sessionID: sessionName)
        if let existing = terminals[handle] { return existing }
        let size = UserDefaults.standard.object(forKey: TerminalAppearance.fontSizeKey) as? Double
        let controller = TouchTerminalController(
            service: viewModel(for: server).service,
            sessionName: sessionName,
            fontSize: size.map { CGFloat($0) } ?? TerminalAppearance.defaultFontSize
        )
        terminals[handle] = controller
        return controller
    }

    /// Cierra (detach) el terminal de una sesión; la sesión tmux sigue viva.
    func closeTerminal(server: Server.ID, sessionName: String) {
        let handle = SessionHandle(serverID: server, sessionID: sessionName)
        terminals.removeValue(forKey: handle)?.stop()
    }

    /// Al volver a primer plano: los PTY murieron con la suspensión, se reabren.
    func reconnectTerminals() {
        for controller in terminals.values where controller.needsReconnect {
            controller.reconnect()
        }
    }

    /// Al pasar a segundo plano: detach limpio antes de que iOS congele la app. Se pide
    /// tiempo extra al sistema para que el cierre del canal llegue al servidor; si no,
    /// queda un cliente tmux fantasma que condiciona el tamaño de ventana de los demás.
    func suspendTerminals() {
        guard !terminals.isEmpty, detachTask == .invalid else { return }
        detachTask = UIApplication.shared.beginBackgroundTask(withName: "argos.detach") { [weak self] in
            MainActor.assumeIsolated { self?.endDetachTask() }
        }
        let controllers = Array(terminals.values)
        Task { @MainActor [weak self] in
            for controller in controllers { await controller.stopAndWait() }
            self?.endDetachTask()
        }
    }

    private func endDetachTask() {
        guard detachTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(detachTask)
        detachTask = .invalid
    }

    // MARK: - Agentes persistentes

    /// Sesión cliente del agente (reutilizada mientras dure la app).
    func agentSession(for info: PersistentAgentInfo, server: Server) -> PersistentAgentSession {
        if let existing = agents[info.id]?.session { return existing }
        let session = PersistentAgentSession(service: viewModel(for: server).service, info: info)
        agents[info.id] = (server.id, session)
        return session
    }

    func register(_ session: PersistentAgentSession, server: Server) {
        agents[session.id] = (server.id, session)
    }

    /// Sesiones de agente abiertas en esta ejecución (para los avisos).
    func agentSessions() -> [(Server.ID, PersistentAgentSession)] {
        agents.values.map { ($0.server, $0.session) }
    }

    /// Segundo plano: deja de leer los logs (los agentes siguen en el servidor).
    func suspendAgents() {
        suspendedAgents = agents.values.map(\.session).filter(\.isAttached)
        suspendedAgents.forEach { $0.detach() }
    }

    func resumeAgents() {
        suspendedAgents.forEach { $0.attach() }
        suspendedAgents = []
    }

    private func disconnect(_ serverID: Server.ID) {
        for (id, entry) in agents where entry.server == serverID {
            entry.session.detach()
            agents.removeValue(forKey: id)
        }
        for handle in terminals.keys where handle.serverID == serverID {
            terminals.removeValue(forKey: handle)?.stop()
        }
        if let viewModel = viewModels.removeValue(forKey: serverID) {
            Task { await viewModel.service.disconnect() }
        }
    }
}
