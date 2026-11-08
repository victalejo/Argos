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
        let previous = loadState()
        let localHosts = TOFUHostKeyValidator.allTrusted(storeURL: knownHostsURL)
        let local = ServerSync.localDocument(
            servers: store.servers, knownHosts: localHosts, previous: previous, now: now
        )
        let remote = ServerSync.decode(cloud.data(forKey: Self.documentKey)) ?? .empty
        let merged = ServerSync.merge(local: local, remote: remote, now: now)

        let updated = ServerSync.applying(merged, to: store.servers)
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

    private func loadState() -> ServerSyncDocument {
        ServerSync.decode(try? Data(contentsOf: stateURL)) ?? .empty
    }

    nonisolated static func defaultStateURL() -> URL {
        ServerStore.defaultStoreURL().deletingLastPathComponent().appendingPathComponent("icloud-sync.json")
    }
}
