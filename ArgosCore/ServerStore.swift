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

    /// Cómo arrancó el almacén. Quien deduce borrados comparando con un estado anterior
    /// (iCloud) solo puede fiarse de la lista si es `.loaded`.
    enum LoadOutcome: Equatable {
        /// No había archivo (primer arranque, o alguien lo borró).
        case missing
        case loaded
        /// Había archivo pero no se pudo leer o decodificar: la lista vacía NO significa
        /// que el usuario borrase sus servidores.
        case unreadable
    }

    @ObservationIgnored let loadOutcome: LoadOutcome

    private let storeURL: URL
    /// El archivo ilegible sigue en disco: hay que apartarlo antes de escribir encima.
    @ObservationIgnored private var mustQuarantineBeforeWrite = false

    /// Se invoca tras cada cambio LOCAL (alta, edición, borrado). Lo usa la
    /// sincronización con iCloud; `replaceAll` (cambios que llegan de iCloud) no lo llama.
    @ObservationIgnored var onLocalChange: (() -> Void)?

    init(storeURL: URL = ServerStore.defaultStoreURL()) {
        self.storeURL = storeURL
        // Primer arranque: lista vacía (la UI muestra el estado "Sin servidores" con
        // un botón para añadir). No se siembra ningún servidor: hacerlo filtraría la
        // infraestructura del autor en cada copia distribuida.
        switch ServerStore.load(from: storeURL) {
        case .success(let servers?):
            self.servers = servers
            self.loadOutcome = .loaded
        case .success(nil):
            self.servers = []
            self.loadOutcome = .missing
        case .failure(let error):
            Log.store.error("servers.json ilegible en \(storeURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            self.servers = []
            self.loadOutcome = .unreadable
            self.mustQuarantineBeforeWrite = true
        }
    }

    // MARK: - CRUD

    func add(_ server: Server) {
        servers.append(server)
        persist()
        onLocalChange?()
    }

    func update(_ server: Server) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        persist()
        onLocalChange?()
    }

    /// Borra el servidor y su passphrase asociada en Keychain.
    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        KeychainStore.deletePassphrase(for: server.id)
        persist()
        onLocalChange?()
    }

    /// Sustituye la lista entera (cambios llegados de iCloud). No avisa a `onLocalChange`.
    func replaceAll(_ newServers: [Server]) {
        guard newServers != servers else { return }
        servers = newServers
        persist()
    }

    func server(withID id: Server.ID?) -> Server? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    // MARK: - Persistencia

    private func persist() {
        // Aparta el archivo ilegible ANTES de sobrescribirlo: así el usuario puede
        // recuperar a mano servidores/bookmarks si la corrupción fue parcial o el fallo
        // de lectura era pasajero.
        if mustQuarantineBeforeWrite {
            Self.backupCorruptFile(at: storeURL)
            mustQuarantineBeforeWrite = false
        }
        do {
            let data = try JSONEncoder().encode(servers)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Log.store.error("No se pudo persistir servers.json: \(String(describing: error), privacy: .public)")
        }
    }

    /// `nil` si el archivo no existe; fallo si existe pero no se puede leer o decodificar.
    private static func load(from url: URL) -> Result<[Server]?, Error> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
        return Result {
            try JSONDecoder().decode([Server].self, from: try Data(contentsOf: url))
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
        )) ?? URL.applicationSupportDirectory

        let directory = base.appendingPathComponent("Argos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("servers.json")
    }
}
