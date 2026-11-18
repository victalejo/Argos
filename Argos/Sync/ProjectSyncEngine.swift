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

    /// Operaciones SFTP simultáneas. Van todas por el MISMO canal SFTP persistente, así
    /// que no consumen cupo de `ChannelGate` (6 canales): los comandos (`mkdir`, `mv`,
    /// limpieza) van aparte, de uno en uno y por lotes, y el resto de la app no se queda
    /// sin turno durante un envío.
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
        let safe = SyncGitFilter.apply(SyncPath.withoutPathsUnderSymlinks(files))
            .filter { !SyncExclusions.isUnsafeGitEntry($0) }
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

    /// Trae la conversación más reciente de Claude Code del proyecto a la carpeta de paso
    /// de la copia local (Terminal la coloca en `~/.claude` al abrir). Devuelve si había
    /// alguna que traer.
    func downloadClaudeSession(remoteRoot: String, to localRoot: URL, service: any SSHServicing) async throws -> Bool {
        let output = try await service.runAgentScript(ClaudeSessionTransfer.directoryCommand(root: remoteRoot))
        guard let directory = ClaudeSessionTransfer.parseDirectory(output) else { return false }
        let files = ClaudeSessionTransfer.latestSessionFiles(in: try await service.syncFileList(root: directory))
        guard !files.isEmpty else { return false }

        let staging = localRoot.appendingPathComponent(ClaudeSessionTransfer.stagingDirectory, isDirectory: true)
        let manager = FileManager.default
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        reset(files: files)
        try await forEachConcurrently(files) { file in
            guard let url = LocalProjectFiles.url(for: file.path, in: staging),
                  LocalProjectFiles.parentIsInside(url, root: staging) else { return }
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await service.downloadSyncFile(root: directory, file: file, to: url)
            try LocalProjectFiles.applyMetadata(of: file, at: url)
        }
        return true
    }

    // MARK: - Mac → servidor

    /// Plan de subida: escanea el Mac y relee el servidor.
    func plan(manifest: SyncManifest, localRoot: URL, service: any SSHServicing) async throws -> (SyncPlan, [SyncFile]) {
        let local = try LocalProjectFiles.scan(root: localRoot)
        let server = try await service.syncFileList(root: manifest.remoteRoot)
        return (SyncPlanner.plan(manifest: manifest.files, local: local, server: server), local)
    }

    /// Aplica el plan (ya sin conflictos) en el servidor. Sube todo a temporales y solo
    /// entonces los coloca (`SyncStaging`): si la subida falla o se cancela, se borran
    /// los temporales y el servidor queda como estaba.
    func upload(plan: SyncPlan, remoteRoot: String, localRoot: URL, service: any SSHServicing) async throws {
        await removeStaleTemporaries(root: remoteRoot, service: service)
        let directories = Set(plan.uploads.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty })
        try await service.makeRemoteDirectories(root: remoteRoot, relativeDirectories: directories.sorted())

        reset(files: plan.uploads)
        totalFiles += plan.deletions.count
        try await stageAndPlace(plan.uploads, root: remoteRoot, from: localRoot, service: service)
        for path in plan.deletions {
            try Task.checkCancellation()
            try await service.deleteRemoteSyncFile(root: remoteRoot, relativePath: path)
            doneFiles += 1
            currentPath = path
        }
    }

    /// Sube la conversación de Claude Code que Terminal dejó en la carpeta de paso de
    /// vuelta (al salir de Claude) a la carpeta de conversaciones del proyecto en el
    /// servidor, para que allí `--continue` siga donde se quedó el Mac. Devuelve si había
    /// alguna; al terminar borra la carpeta de paso.
    func uploadClaudeSession(remoteRoot: String, from localRoot: URL, service: any SSHServicing) async throws -> Bool {
        let export = localRoot.appendingPathComponent(ClaudeSessionTransfer.exportDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: export.path) else { return false }
        let files = ClaudeSessionTransfer.latestSessionFiles(in: try LocalProjectFiles.scan(root: export))
        guard !files.isEmpty else { return false }

        let output = try await service.runAgentScript(ClaudeSessionTransfer.ensureDirectoryCommand(root: remoteRoot))
        guard let directory = ClaudeSessionTransfer.parseDirectory(output) else { return false }
        let directories = Set(files.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty })
        try await service.makeRemoteDirectories(root: directory, relativeDirectories: directories.sorted())

        reset(files: files)
        try await stageAndPlace(files, root: directory, from: export, service: service)
        try? FileManager.default.removeItem(at: export)
        return true
    }

    // MARK: - Temporales del servidor

    /// Sube `files` a temporales en paralelo (solo SFTP: no ocupa canales de comandos) y
    /// los coloca después con pocos `mv` por lotes. Ante un fallo o una cancelación borra
    /// los temporales que queden; los ya colocados son la versión nueva, completa.
    private func stageAndPlace(_ files: [SyncFile], root: String, from localRoot: URL, service: any SSHServicing) async throws {
        let sendable = files.filter { LocalProjectFiles.url(for: $0.path, in: localRoot) != nil }
        do {
            try await forEachConcurrently(sendable) { file in
                guard let url = LocalProjectFiles.url(for: file.path, in: localRoot) else { return }
                try await service.stageSyncFile(root: root, file: file, from: url)
            }
            try Task.checkCancellation()
            try await service.placeStagedSyncFiles(root: root, files: sendable)
        } catch {
            discardInBackground(root: root, paths: sendable.map(\.path), service: service)
            throw error
        }
    }

    /// Huérfanos de envíos interrumpidos: un fallo no impide enviar (se registra).
    private func removeStaleTemporaries(root: String, service: any SSHServicing) async {
        do {
            try await service.removeStaleSyncTemporaries(root: root)
        } catch {
            Log.store.error("No se limpiaron los temporales antiguos de \(root, privacy: .public): \(error.userMessage, privacy: .public)")
        }
    }

    /// Borra los temporales tras un fallo o una cancelación. En una tarea aparte: la del
    /// envío puede estar cancelada. Lo que quede, lo limpia el siguiente envío.
    private func discardInBackground(root: String, paths: [String], service: any SSHServicing) {
        Task {
            do {
                try await service.discardStagedSyncFiles(root: root, paths: paths)
            } catch {
                Log.store.error("Temporales de subida sin borrar en \(root, privacy: .public): \(error.userMessage, privacy: .public)")
            }
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
