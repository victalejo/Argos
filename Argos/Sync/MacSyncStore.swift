//
//  MacSyncStore.swift
//  Argos
//
//  Estado LOCAL de "Enviar al Mac": la carpeta del Mac donde se dejan las copias
//  (elegida una vez; bookmark con alcance de seguridad porque la app está en sandbox) y
//  el manifiesto de cada proyecto enviado (Application Support/Argos/sync/<id>.json).
//

import AppKit
import Foundation

@MainActor
enum MacSyncStore {

    private static let destinationKey = "sync.destinationBookmark"
    private static let macIDKey = "sync.macID"

    // MARK: - Identidad del Mac

    /// Identificador estable de ESTE Mac (para saber si un proyecto está aquí).
    static var macID: String {
        if let id = UserDefaults.standard.string(forKey: macIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: macIDKey)
        return id
    }

    static var macName: String {
        Host.current().localizedName ?? "este Mac"
    }

    // MARK: - Carpeta destino

    /// Carpeta del Mac donde se crean las copias, si ya se eligió.
    static func destination() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: destinationKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(fresh, forKey: destinationKey)
        }
        return url
    }

    /// Pide al usuario la carpeta destino (p. ej. ~/Desarrollo) y la recuerda.
    static func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "¿Dónde guardo los proyectos en este Mac?"
        panel.message = "Cada proyecto se copiará en una subcarpeta con su nombre."
        panel.prompt = "Usar esta carpeta"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desarrollo")
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return nil }
        UserDefaults.standard.set(bookmark, forKey: destinationKey)
        return url
    }

    // MARK: - Manifiestos

    private static var manifestsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Argos/sync", isDirectory: true)
    }

    private static func manifestURL(for projectID: UUID, in directory: URL = manifestsDirectory) -> URL {
        directory.appendingPathComponent("\(projectID.uuidString).json")
    }

    /// Manifiesto del proyecto: `nil` si este Mac no tiene copia; LANZA si el archivo
    /// existe pero no se puede leer o decodificar (para no confundirlo con "no hay copia").
    static func loadManifest(for projectID: UUID, in directory: URL = manifestsDirectory) throws -> SyncManifest? {
        let url = manifestURL(for: projectID, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.store.info("Sin manifiesto de envío para \(projectID.uuidString, privacy: .public) en \(url.path, privacy: .public)")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder.projects.decode(SyncManifest.self, from: data)
        } catch {
            Log.store.error("Manifiesto de envío ilegible (\(url.path, privacy: .public)): \(String(describing: error), privacy: .public)")
            throw ManifestError.unreadable(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Variante sin errores para la UI (menús): el fallo ya queda registrado en el log.
    static func manifest(for projectID: UUID) -> SyncManifest? {
        (try? loadManifest(for: projectID)) ?? nil
    }

    enum ManifestError: LocalizedError {
        case unreadable(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path, let reason):
                return "No se pudo leer el registro del envío (\(path)): \(reason)"
            }
        }
    }

    static func save(_ manifest: SyncManifest) throws {
        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)
        try JSONEncoder.projects.encode(manifest).write(to: manifestURL(for: manifest.projectID), options: .atomic)
    }

    static func deleteManifest(for projectID: UUID) {
        try? FileManager.default.removeItem(at: manifestURL(for: projectID))
    }

    /// URL de la copia local con su alcance de seguridad resuelto.
    static func localFolder(of manifest: SyncManifest) -> URL? {
        if let bookmark = manifest.localBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(fileURLWithPath: manifest.localPath, isDirectory: true)
    }

    /// Ejecuta `body` con acceso (sandbox) a `url`.
    static func withAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }
}
