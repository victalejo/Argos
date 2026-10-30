//
//  ProjectSyncEngine.swift
//  Argos
//
//  Ejecuta "Enviar al Mac" y "Enviar al servidor" con progreso observable. Transfiere
//  en paralelo (pocas operaciones SFTP a la vez sobre el mismo canal) y respeta la
//  cancelación. No sabe de sandbox: recibe URLs ya accesibles (ver `MacSyncStore`).
//

import Foundation
import Observation

@MainActor
@Observable
final class ProjectSyncEngine {

    private(set) var totalFiles = 0
    private(set) var doneFiles = 0
    private(set) var totalBytes: UInt64 = 0
    private(set) var doneBytes: UInt64 = 0
    private(set) var currentPath: String?

    /// Operaciones SFTP simultáneas.
    static let concurrency = 6

    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(doneBytes) / Double(totalBytes)) }
        return totalFiles > 0 ? Double(doneFiles) / Double(totalFiles) : 0
    }

    private func reset(files: [SyncFile]) {
        totalFiles = files.count
        doneFiles = 0
        totalBytes = files.reduce(0) { $0 + $1.size }
        doneBytes = 0
        currentPath = nil
    }

    private func completed(_ file: SyncFile) {
        doneFiles += 1
        doneBytes += file.size
        currentPath = file.path
    }

    // MARK: - Servidor → Mac

    enum SendError: LocalizedError {
        case destinationNotEmpty(String)

        var errorDescription: String? {
            switch self {
            case .destinationNotEmpty(let path):
                return "Ya existe una carpeta con contenido en \(path). Elige otra carpeta destino o muévela."
            }
        }
    }

    /// Descarga `files` del servidor a `localRoot` (que no debe tener contenido) y
    /// devuelve el estado transferido para el manifiesto.
    func download(
        files: [SyncFile],
        from remoteRoot: String,
        to localRoot: URL,
        service: any SSHServicing
    ) async throws -> [String: SyncFile] {
        let manager = FileManager.default
        if let existing = try? manager.contentsOfDirectory(atPath: localRoot.path), !existing.isEmpty {
            throw SendError.destinationNotEmpty(localRoot.path)
        }
        try manager.createDirectory(at: localRoot, withIntermediateDirectories: true)

        // El listado viene del servidor: nada que cuelgue de un enlace (seguirlo podría
        // escribir fuera de la carpeta) y solo enlaces relativos que no salgan de ella.
        let safe = SyncPath.withoutPathsUnderSymlinks(files).filter { !SyncExclusions.isUnsafeGitEntry($0) }
        let regular = safe.filter { !$0.isSymlink }
        let links = safe.filter { $0.isSymlink && SyncPath.isSafeSymlink(path: $0.path, target: $0.linkTarget ?? "") }

        // Carpetas primero (de una vez), luego archivos en paralelo y los enlaces AL FINAL
        // (así ningún archivo se escribe a través de un enlace recién creado).
        let directories = Set(regular.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty })
        for directory in directories.sorted() {
            guard let url = LocalProjectFiles.url(for: directory, in: localRoot) else { continue }
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        reset(files: regular + links)
        try await forEachConcurrently(regular) { file in
            guard let url = LocalProjectFiles.url(for: file.path, in: localRoot),
                  LocalProjectFiles.parentIsInside(url, root: localRoot) else { return }
            if SyncExclusions.isUploadExcluded(file.path) {
                // Config de git: se descarga a un temporal y se RECONSTRUYE (lista blanca);
                // nunca existe en su sitio la versión cruda del servidor.
                let raw = url.appendingPathExtension("argos-raw")
                try await service.downloadSyncFile(root: remoteRoot, file: file, to: raw)
                try LocalProjectFiles.rebuildGitConfig(from: raw, to: url)
                return
            }
            try await service.downloadSyncFile(root: remoteRoot, file: file, to: url)
            try LocalProjectFiles.applyMetadata(of: file, at: url)
        }
        for link in links {
            try Task.checkCancellation()
            guard let url = LocalProjectFiles.url(for: link.path, in: localRoot),
                  LocalProjectFiles.parentIsInside(url, root: localRoot) else { continue }
            try LocalProjectFiles.makeSymlink(link, at: url)
            // Comprobación final sobre el sistema de archivos REAL: si el enlace (p. ej.
            // encadenado con otro) acaba fuera de la carpeta, se borra.
            if !LocalProjectFiles.resolvesInside(url, root: localRoot) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            completed(link)
        }
        // El manifiesto solo recoge lo que realmente se trajo.
        return Dictionary((regular + links).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Mac → servidor

    /// Plan de subida: escanea el Mac y relee el servidor.
    func plan(manifest: SyncManifest, localRoot: URL, service: any SSHServicing) async throws -> (SyncPlan, [SyncFile]) {
        let local = try LocalProjectFiles.scan(root: localRoot)
        let server = try await service.syncFileList(root: manifest.remoteRoot)
        return (SyncPlanner.plan(manifest: manifest.files, local: local, server: server), local)
    }

    /// Aplica el plan (ya sin conflictos) en el servidor.
    func upload(plan: SyncPlan, remoteRoot: String, localRoot: URL, service: any SSHServicing) async throws {
        let directories = Set(plan.uploads.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty })
        try await service.makeRemoteDirectories(root: remoteRoot, relativeDirectories: directories.sorted())

        reset(files: plan.uploads)
        totalFiles += plan.deletions.count
        try await forEachConcurrently(plan.uploads) { file in
            guard let url = LocalProjectFiles.url(for: file.path, in: localRoot) else { return }
            try await service.uploadSyncFile(root: remoteRoot, file: file, from: url)
        }
        for path in plan.deletions {
            try Task.checkCancellation()
            try await service.deleteRemoteSyncFile(root: remoteRoot, relativePath: path)
            doneFiles += 1
            currentPath = path
        }
    }

    // MARK: - Concurrencia

    private func forEachConcurrently(
        _ files: [SyncFile],
        _ operation: @escaping @MainActor (SyncFile) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: SyncFile.self) { group in
            var iterator = files.makeIterator()
            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    try await operation(file)
                    return file
                }
                return true
            }
            for _ in 0..<Self.concurrency where !addNext() { break }
            while let file = try await group.next() {
                completed(file)
                _ = addNext()
            }
        }
    }
}
