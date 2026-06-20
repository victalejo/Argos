//
//  ServerStore.swift
//  Argos
//
//  Almacén observable de servidores SSH, persistido como JSON en
//  ~/Library/Application Support/Argos/servers.json. Reemplaza la antigua
//  configuración única hardcodeada por una lista editable desde la UI.
//

import Foundation
import Observation

@MainActor
@Observable
final class ServerStore {

    /// Servidores configurados, en orden de visualización.
    private(set) var servers: [Server]

    private let storeURL: URL

    init(storeURL: URL = ServerStore.defaultStoreURL()) {
        self.storeURL = storeURL
        // Primer arranque: lista vacía (la UI muestra el estado "Sin servidores" con
        // un botón para añadir). No se siembra ningún servidor: hacerlo filtraría la
        // infraestructura del autor en cada copia distribuida.
        self.servers = ServerStore.load(from: storeURL) ?? []
    }

    // MARK: - CRUD

    func add(_ server: Server) {
        servers.append(server)
        persist()
    }

    func update(_ server: Server) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        persist()
    }

    /// Borra el servidor y su passphrase asociada en Keychain.
    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        KeychainStore.deletePassphrase(for: server.id)
        persist()
    }

    func server(withID id: Server.ID?) -> Server? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    // MARK: - Persistencia

    private func persist() {
        do {
            let data = try JSONEncoder().encode(servers)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Log.store.error("No se pudo persistir servers.json: \(String(describing: error), privacy: .public)")
        }
    }

    /// `nil` si el archivo no existe (primer arranque); `[]` si existe pero corrupto
    /// (tras moverlo a un backup para no perder los bookmarks de clave que contuviera).
    private static func load(from url: URL) -> [Server]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Server].self, from: data)
        } catch {
            Log.store.error("servers.json corrupto en \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            // Mueve el archivo corrupto a un backup ANTES de que el primer `add`
            // sobrescriba (irreversiblemente) la config. Así el usuario puede
            // recuperar a mano servidores/bookmarks si la corrupción fue parcial.
            backupCorruptFile(at: url)
            return []
        }
    }

    /// Renombra `servers.json` corrupto a `servers.json.corrupt-<epoch>` (best-effort).
    private static func backupCorruptFile(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            Log.store.notice("servers.json corrupto respaldado en \(backup.path, privacy: .public)")
        } catch {
            Log.store.error("No se pudo respaldar servers.json corrupto: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func defaultStoreURL() -> URL {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        let directory = base.appendingPathComponent("Argos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("servers.json")
    }
}
