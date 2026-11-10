//
//  GitHubCloneModel.swift
//  ArgosCore
//
//  «Clonar de GitHub» del formulario de nuevo proyecto: lista los repositorios del
//  usuario de `gh` (en el servidor), propone la carpeta y clona. El formulario crea el
//  proyecto con la ruta que devuelve `clone()`.
//

import Foundation
import Observation

@MainActor
@Observable
final class GitHubCloneModel {
    enum RepositoriesState: Equatable {
        case idle, loading, ghMissing, notAuthenticated
        case loaded([GitHubRepository])
        case failed(String)
    }

    private let service: any SSHServicing

    private(set) var repositories: RepositoriesState = .idle
    private(set) var isCloning = false
    var repository = "" {
        didSet { if !folderEdited { folder = GitHubCloneRequest.defaultFolder(for: repository) } }
    }
    /// Carpeta del servidor DENTRO de la cual se clona.
    var parent = "~"
    var folder = "" {
        didSet { if folder != GitHubCloneRequest.defaultFolder(for: repository) { folderEdited = true } }
    }
    private var folderEdited = false

    init(service: any SSHServicing) {
        self.service = service
    }

    /// Ruta final que se creará (para enseñarla en el formulario).
    var destination: String {
        let base = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        return folder.isEmpty ? base : "\(base)/\(folder)"
    }

    var validationError: String? {
        do {
            _ = try GitHubCloneRequest.make(repository: repository, parent: parent, folder: folder)
            return nil
        } catch {
            return error.userMessage
        }
    }

    var canClone: Bool { !isCloning && validationError == nil }

    /// Lista de repositorios (una vez; `force` para recargar).
    func loadRepositories(force: Bool = false) async {
        if !force, repositories != .idle { return }
        repositories = .loading
        do {
            switch try await service.gitHubRepositories() {
            case .ghMissing: repositories = .ghMissing
            case .notAuthenticated: repositories = .notAuthenticated
            case .failed(let message): repositories = .failed(message)
            case .loaded(let list):
                repositories = .loaded(list.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) })
            }
        } catch {
            repositories = .failed(error.userMessage)
        }
    }

    func choose(_ repo: GitHubRepository) {
        folderEdited = false
        repository = repo.nameWithOwner
    }

    /// Clona y devuelve la ruta absoluta creada. Lanza con un mensaje para el usuario.
    func clone() async throws -> String {
        let request = try GitHubCloneRequest.make(repository: repository, parent: parent, folder: folder)
        isCloning = true
        defer { isCloning = false }
        return try await service.gitHubClone(request)
    }
}
