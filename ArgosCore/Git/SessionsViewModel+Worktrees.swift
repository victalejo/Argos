//
//  SessionsViewModel+Worktrees.swift
//  ArgosCore
//
//  «Ramas en paralelo»: crear un worktree como proyecto nuevo (mismo grupo que el
//  original, su propia sesión y su agente) y quitarlo (detiene su sesión, quita el
//  worktree y su proyecto). La rama se conserva siempre.
//

import Foundation

extension SessionsViewModel {

    /// Nombre del proyecto de un worktree: «app-feat-login».
    nonisolated static func worktreeProjectName(parent: Project, branch: String) -> String {
        "\(parent.name)-\(GitBranchName.projectSlug(branch))"
    }

    /// Proyecto cuya carpeta es `path` (sin la barra final).
    func project(atPath path: String) -> Project? {
        let wanted = Self.normalized(path)
        return projects.first { Self.normalized($0.path) == wanted }
    }

    /// Crea el worktree y lo registra como proyecto (heredando grupo y comando de arranque
    /// del original). Con `start`, arranca ya su sesión (y con ella el agente).
    @discardableResult
    func createWorktreeProject(
        from parent: Project, request: GitWorktreeRequest, start: Bool, defaultStartupCommand: String
    ) async throws -> Project {
        var project = Project(
            name: Self.worktreeProjectName(parent: parent, branch: request.branch),
            group: parent.group,
            path: request.path,
            startupCommand: parent.startupCommand
        )
        // Se valida ANTES de crear nada: un nombre repetido no debe dejar un worktree huérfano.
        _ = try ProjectListing.validate(project, among: projects, looseSessions: projectListing.looseSessions)
        project.path = try await service.gitAddWorktree(request)
        try await saveProject(project)
        if start { try await openProject(project, defaultStartupCommand: defaultStartupCommand) }
        return project
    }

    /// Quita un worktree: detiene la sesión de su proyecto (si corre), lo quita con git
    /// (`force`: aunque tenga cambios sin confirmar) y quita su proyecto de Argos.
    func removeWorktree(_ worktree: GitWorktree, repository: String, force: Bool) async throws {
        guard !worktree.isMain else { return }
        let project = project(atPath: worktree.path)
        if let project, session(withID: project.sessionName) != nil {
            try await service.stopSession(named: project.sessionName)
        }
        try await service.gitRemoveWorktree(repository: repository, path: worktree.path, force: force)
        if let project {
            try await removeProject(project)
        } else {
            await refresh()
        }
    }

    nonisolated private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
