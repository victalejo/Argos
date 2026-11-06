//
//  FileBrowserModel.swift
//  Argos
//
//  Estado del explorador de un proyecto: árbol cargado por carpetas a demanda (solo al
//  expandir), archivo seleccionado y su contenido, e índice para la búsqueda rápida.
//

import Foundation
import Observation

/// Fila visible del árbol (entrada + nivel de sangría).
struct FileTreeRow: Identifiable, Hashable, Sendable {
    let entry: RemoteFileEntry
    let depth: Int
    var id: String { entry.path }
}

enum FilePreviewState {
    case empty
    case loading(RemoteFileEntry)
    case loaded(RemoteFileEntry, RemoteFileContent, FilePreviewKind)
    case failed(RemoteFileEntry, String)
}

@MainActor
@Observable
final class FileBrowserModel {
    let root: String
    private let service: any SSHServicing

    private(set) var children: [String: [RemoteFileEntry]] = [:]
    private(set) var expanded: Set<String> = []
    private(set) var loadingDirectories: Set<String> = []
    private(set) var directoryErrors: [String: String] = [:]
    private(set) var preview: FilePreviewState = .empty
    private(set) var fileIndex: [String]?
    /// Última descarga al Mac (`nil` = ninguna que mostrar).
    var downloadStatus: FileDownloadStatus?
    var showHidden = false

    init(root: String, service: any SSHServicing) {
        self.root = root
        self.service = service
    }

    var rootName: String { (root as NSString).lastPathComponent }

    /// Filas visibles: el árbol aplanado según qué carpetas están expandidas.
    var rows: [FileTreeRow] {
        Self.flatten(root: root, children: children, expanded: expanded, showHidden: showHidden)
    }

    /// Lógica pura del aplanado (testeable).
    nonisolated static func flatten(
        root: String,
        children: [String: [RemoteFileEntry]],
        expanded: Set<String>,
        showHidden: Bool
    ) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func visit(_ directory: String, depth: Int) {
            for entry in children[directory] ?? [] where entry.isVisible(showHidden: showHidden) {
                rows.append(FileTreeRow(entry: entry, depth: depth))
                if entry.isDirectory && expanded.contains(entry.path) {
                    visit(entry.path, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 0)
        return rows
    }

    // MARK: - Árbol

    func loadRootIfNeeded() async {
        guard children[root] == nil else { return }
        await load(root)
    }

    func toggle(_ directory: RemoteFileEntry) async {
        guard directory.isDirectory else { return }
        if expanded.contains(directory.path) {
            expanded.remove(directory.path)
        } else {
            expanded.insert(directory.path)
            if children[directory.path] == nil { await load(directory.path) }
        }
    }

    /// Recarga las carpetas abiertas (p. ej. tras cambios hechos por Claude).
    func refresh() async {
        let openDirectories = [root] + expanded.sorted()
        fileIndex = nil
        for directory in openDirectories { await load(directory) }
        if case .loaded(let entry, _, _) = preview { await open(entry) }
    }

    private func load(_ directory: String) async {
        loadingDirectories.insert(directory)
        defer { loadingDirectories.remove(directory) }
        do {
            children[directory] = try await service.listRemoteDirectory(directory, root: root)
            directoryErrors[directory] = nil
        } catch {
            directoryErrors[directory] = error.userMessage
        }
    }

    // MARK: - Archivo

    func open(_ entry: RemoteFileEntry) async {
        guard !entry.isDirectory else { return }
        preview = .loading(entry)
        let byName = FilePreview.kind(forName: entry.name)
        let limit = FilePreview.readLimit(for: byName)
        do {
            let content = try await service.readRemoteFile(entry.path, root: root, maxBytes: limit)
            // Si mientras tanto se eligió otro archivo, no se pisa su vista.
            guard case .loading(let current) = preview, current.path == entry.path else { return }
            preview = .loaded(entry, content, FilePreview.kind(forName: entry.name, data: content.data))
        } catch {
            preview = .failed(entry, error.userMessage)
        }
    }

    /// Descarga el archivo COMPLETO a `destination` (elegida por el usuario en el Mac)
    /// y deja el resultado en `downloadStatus`.
    func downloadToMac(_ entry: RemoteFileEntry, to destination: URL) async {
        downloadStatus = .downloading(name: entry.name)
        do {
            try await service.downloadRemoteFile(entry.path, root: root, to: destination)
            downloadStatus = .saved(destination)
        } catch {
            downloadStatus = .failed(name: entry.name, message: error.userMessage)
        }
    }

    /// Abre un archivo por su ruta relativa (desde la búsqueda rápida) y despliega sus
    /// carpetas en el árbol para que se vea dónde está.
    func open(relativePath: String) async {
        let components = relativePath.split(separator: "/").map(String.init)
        var directory = root
        for component in components.dropLast() {
            directory = RemotePath.join(directory, component)
            expanded.insert(directory)
            if children[directory] == nil { await load(directory) }
        }
        let path = RemotePath.join(root, relativePath)
        let name = components.last ?? relativePath
        await open(RemoteFileEntry(name: name, path: path, kind: .file))
    }

    // MARK: - Búsqueda rápida

    func loadIndexIfNeeded() async {
        guard fileIndex == nil else { return }
        fileIndex = (try? await service.indexProjectFiles(root: root)) ?? []
    }

    /// Mejores coincidencias difusas para la búsqueda rápida (máx. `limit`).
    nonisolated static func matches(_ query: String, in index: [String], limit: Int = 60) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(index.prefix(limit)) }
        return index
            .compactMap { path -> (String, Int)? in
                guard let score = FuzzyMatcher.score(trimmed, in: path) else { return nil }
                // Bonus si coincide con el NOMBRE del archivo, no solo con la ruta.
                let name = (path as NSString).lastPathComponent
                let bonus = FuzzyMatcher.score(trimmed, in: name).map { $0 + 50 } ?? 0
                return (path, score + bonus - path.count / 8)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
