//
//  WorktreesModel.swift
//  ArgosCore
//
//  Hoja «Ramas en paralelo» de un proyecto: lista los worktrees de su repositorio y crea
//  uno nuevo (rama nueva desde otra, o una rama existente) como proyecto con su agente.
//  La carpeta sigue a la rama hasta que el usuario la cambia.
//

import Foundation
import Observation

@MainActor
@Observable
final class WorktreesModel {
    enum LoadState: Equatable {
        case loading, gitMissing, notRepository
        case loaded(GitWorktreeListing)
        case failed(String)
    }

    let parent: Project
    private let viewModel: SessionsViewModel

    private(set) var state: LoadState = .loading
    private(set) var isWorking = false
    var errorMessage: String?
    var notice: String?

    // Formulario de rama nueva
    var createsBranch = true {
        didSet { if !createsBranch, !freeBranches.contains(branch) { branch = freeBranches.first ?? "" } }
    }
    var branch = "" {
        didSet { if !pathEdited { path = suggestedPath } }
    }
    var base = "HEAD"
    var path = "" {
        didSet { if path != suggestedPath { pathEdited = true } }
    }
    /// Arrancar ya la sesión (y el agente) del worktree nuevo.
    var startsAgent = true
    private var pathEdited = false

    init(parent: Project, viewModel: SessionsViewModel) {
        self.parent = parent
        self.viewModel = viewModel
    }

    var listing: GitWorktreeListing? {
        if case .loaded(let listing) = state { return listing }
        return nil
    }

    var freeBranches: [String] { listing?.freeBranches ?? [] }

    /// Ramas desde las que puede nacer la nueva (`HEAD` = la actual del original).
    var baseOptions: [String] { ["HEAD"] + (listing?.branches ?? []) }

    var projectName: String { SessionsViewModel.worktreeProjectName(parent: namingParent, branch: branch) }

    /// Proyecto del que heredan nombre, grupo y comando los worktrees nuevos: el del
    /// worktree principal si está en Argos (abrir la hoja desde un worktree no encadena
    /// nombres «app-feat-x-feat-y»), o el proyecto desde el que se abrió.
    var namingParent: Project {
        listing?.main.flatMap { viewModel.project(atPath: $0.path) } ?? parent
    }

    private var suggestedPath: String {
        guard !branch.isEmpty else { return "" }
        return listing?.defaultPath(forBranch: branch) ?? ""
    }

    /// Proyecto de Argos de un worktree (si lo tiene).
    func project(for worktree: GitWorktree) -> Project? { viewModel.project(atPath: worktree.path) }

    func isRunning(_ worktree: GitWorktree) -> Bool {
        guard let project = project(for: worktree) else { return false }
        return viewModel.session(withID: project.sessionName) != nil
    }

    var validationError: String? {
        guard let listing else { return nil }
        do {
            _ = try GitWorktreeRequest.make(listing: listing, branch: branch, createsBranch: createsBranch,
                                            base: base, path: path)
            return nil
        } catch {
            return error.userMessage
        }
    }

    var canCreate: Bool { !isWorking && !branch.isEmpty && validationError == nil }

    func load() async {
        do {
            switch try await viewModel.service.gitWorktrees(at: parent.path) {
            case .gitMissing: state = .gitMissing
            case .notRepository: state = .notRepository
            case .loaded(let listing):
                state = .loaded(listing)
                if !pathEdited { path = suggestedPath }
            }
        } catch {
            if listing == nil { state = .failed(error.userMessage) }
        }
    }

    /// Crea el worktree como proyecto. Devuelve el proyecto creado (o `nil` si falló).
    @discardableResult
    func create(defaultStartupCommand: String) async -> Project? {
        guard canCreate, let listing else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let request = try GitWorktreeRequest.make(listing: listing, branch: branch, createsBranch: createsBranch,
                                                      base: base, path: path)
            let project = try await viewModel.createWorktreeProject(
                from: namingParent, request: request, start: startsAgent, defaultStartupCommand: defaultStartupCommand
            )
            notice = "Creado «\(project.name)» en la rama \(request.branch)."
            pathEdited = false
            branch = ""
            await load()
            return project
        } catch {
            errorMessage = error.userMessage
            await load()
            return nil
        }
    }

    /// Quita un worktree (y su proyecto). `force`: aunque tenga cambios sin confirmar.
    func remove(_ worktree: GitWorktree, force: Bool) async {
        guard !worktree.isMain, let main = listing?.main else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await viewModel.removeWorktree(worktree, repository: main.path, force: force)
            notice = "Quitado el worktree de \(worktree.displayBranch). La rama se conserva."
        } catch {
            errorMessage = error.userMessage
        }
        await load()
    }

    /// Registra como proyecto un worktree que existía sin proyecto (creado a mano).
    func adopt(_ worktree: GitWorktree) async {
        guard let branch = worktree.branch else { return }
        isWorking = true
        defer { isWorking = false }
        let base = namingParent
        let project = Project(
            name: SessionsViewModel.worktreeProjectName(parent: base, branch: branch),
            group: base.group, path: worktree.path, startupCommand: base.startupCommand
        )
        do {
            try await viewModel.saveProject(project)
            notice = "Añadido «\(project.name)» a tus proyectos."
        } catch {
            errorMessage = error.userMessage
        }
    }
}
