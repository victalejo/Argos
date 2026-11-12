//
//  CloudServerSync.swift
//  Argos
//
//  Sincroniza servidores y huellas confiadas por iCloud (almacén clave-valor), entre la
//  app de Mac (canal App Store) y la de iPhone/iPad. Ver `ServerSyncDocument` para qué
//  viaja (nunca secretos) y cómo se fusiona.
//

import Foundation

/// Lo mínimo del almacén clave-valor de iCloud (inyectable en tests).
protocol CloudKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

final class UbiquitousKeyValueStore: CloudKeyValueStore {
    private let store = NSUbiquitousKeyValueStore.default
    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func setData(_ data: Data?, forKey key: String) { store.set(data, forKey: key) }
    @discardableResult func synchronize() -> Bool { store.synchronize() }
}

@MainActor
final class CloudServerSync {

    static let documentKey = "servers.v1"
    static let enabledKey = "cloudSync.enabled"

    private let store: ServerStore
    private let cloud: CloudKeyValueStore
    private let defaults: UserDefaults
    private let stateURL: URL
    private let knownHostsURL: URL
    /// Para limpiar lo propio de un servidor borrado en otro dispositivo (secretos,
    /// conexiones…).
    var onRemoteRemoval: ((Server) -> Void)?
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    init(
        store: ServerStore,
        cloud: CloudKeyValueStore = UbiquitousKeyValueStore(),
        defaults: UserDefaults = .standard,
        stateURL: URL = CloudServerSync.defaultStateURL(),
        knownHostsURL: URL = TOFUHostKeyValidator.defaultStoreURL()
    ) {
        self.store = store
        self.cloud = cloud
        self.defaults = defaults
        self.stateURL = stateURL
        self.knownHostsURL = knownHostsURL
    }

    /// Activada por defecto; el usuario puede apagarla en Ajustes.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if newValue { sync() }
        }
    }

    /// Empieza a escuchar cambios locales y remotos y hace una primera sincronización.
    func start() {
        discardStateIfLocalListIsUntrustworthy()
        store.onLocalChange = { [weak self] in self?.scheduleSync() }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        cloud.synchronize()
        sync()
    }

    /// Agrupa ráfagas de cambios locales en una sola escritura.
    func scheduleSync() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    func sync(now: Date = Date()) {
        guard isEnabled else { return }
        // Con el registro de huellas dañado no se puede saber qué se olvidó aquí: se
        // espera a que el usuario lo resuelva en vez de propagar «olvidadas todas».
        guard TOFUHostKeyValidator.isReadable(storeURL: knownHostsURL) else {
            Log.store.error("Registro de huellas ilegible: no se sincroniza con iCloud.")
            return
        }
        let previous = loadState()
        let localHosts = TOFUHostKeyValidator.allTrusted(storeURL: knownHostsURL)
        let local = ServerSync.localDocument(
            servers: store.servers, knownHosts: localHosts, previous: previous, now: now
        )
        // Un documento remoto ilegible o de una versión más nueva NO se trata como vacío:
        // se aborta sin escribir (si no, esta app borraría lo que otra versión guardó).
        let remote: ServerSyncDocument
        if let raw = cloud.data(forKey: Self.documentKey) {
            guard let decoded = ServerSync.decode(raw),
                  decoded.version <= ServerSyncDocument.supportedVersion else {
                Log.store.error("Documento de iCloud ilegible o de una versión más nueva: no se sincroniza.")
                return
            }
            remote = decoded
        } else {
            remote = .empty
        }
        let merged = ServerSync.merge(local: local, remote: remote, now: now)

        let updated = ServerSync.applying(merged, to: store.servers)
        for id in ServerSync.credentialsToInvalidate(before: store.servers, after: updated) {
            KeychainStore.deletePassword(for: id)
            KeychainStore.deletePassphrase(for: id)
            Log.store.notice("iCloud cambió el destino de un servidor: se borran sus secretos locales.")
        }
        let survivors = Set(updated.map(\.id))
        for removed in store.servers where !survivors.contains(removed.id) {
            onRemoteRemoval?(removed)
        }
        store.replaceAll(updated)

        let hosts = ServerSync.hostChanges(in: merged, local: localHosts)
        TOFUHostKeyValidator.trust(hosts.add, storeURL: knownHostsURL)
        TOFUHostKeyValidator.forget(endpoints: hosts.forget, storeURL: knownHostsURL)

        do {
            let data = try ServerSync.encode(merged)
            if data != cloud.data(forKey: Self.documentKey) {
                cloud.setData(data, forKey: Self.documentKey)
            }
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Log.store.error("Sincronización con iCloud: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Los borrados se deducen comparando la lista local con lo último sincronizado. Si
    /// `servers.json` no se pudo leer (o desapareció), la lista vacía no es una decisión
    /// del usuario: sin esto se publicarían lápidas de TODOS los servidores y los demás
    /// dispositivos los borrarían junto con sus secretos. Olvidando lo último sincronizado
    /// este dispositivo pasa a comportarse como uno nuevo y adopta lo que haya en iCloud.
    private func discardStateIfLocalListIsUntrustworthy() {
        guard store.loadOutcome != .loaded, store.servers.isEmpty,
              FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: stateURL)
            Log.store.notice("Lista local de servidores no fiable: se adopta la de iCloud sin publicar borrados.")
        } catch {
            Log.store.error("No se pudo descartar el estado de iCloud: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadState() -> ServerSyncDocument {
        ServerSync.decode(try? Data(contentsOf: stateURL)) ?? .empty
    }

    nonisolated static func defaultStateURL() -> URL {
        ServerStore.defaultStoreURL().deletingLastPathComponent().appendingPathComponent("icloud-sync.json")
    }
}
