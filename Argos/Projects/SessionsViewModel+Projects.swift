//
//  SessionsViewModel+Projects.swift
//  Argos
//
//  Ciclo de vida de los proyectos de un servidor: crear/editar/quitar (en
//  projects.json del servidor), importar sesiones existentes, abrir (crear la sesión
//  en la carpeta + comando de arranque) y detener (kill-session; el proyecto queda).
//

import Foundation

extension SessionsViewModel {

    /// Proyectos cruzados con las sesiones vivas, y sesiones sin proyecto.
    var projectListing: (entries: [ProjectEntry], looseSessions: [TmuxSession]) {
        ProjectListing.build(projects: projects, sessions: sessions)
    }

    func project(forSession sessionName: String) -> Project? {
        projects.first { $0.sessionName == sessionName }
    }

    /// Relee projects.json. Un fallo no tumba la lista de sesiones: se muestra aparte.
    func reloadProjects() async {
        do {
            projects = try await service.loadProjects()
            projectsError = nil
        } catch {
            Log.store.error("Leer proyectos: \(error.userMessage, privacy: .public)")
            projectsError = error.userMessage
        }
    }

    // MARK: - Alta / edición / baja

    /// Crea o actualiza (mismo `id`) un proyecto. Si cambia el nombre de un proyecto
    /// en marcha, renombra también su sesión tmux para no perderla.
    ///
    /// - Parameter adoptedSession: sesión suelta que se convierte en este proyecto
    ///   ("Convertir en proyecto"): su nombre no cuenta como duplicado.
    func saveProject(_ project: Project, adoptingSession adoptedSession: String? = nil) async throws {
        let others = projects
        let validated = try ProjectListing.validate(
            project,
            among: others,
            looseSessions: projectListing.looseSessions.filter { $0.name != adoptedSession }
        )
        if let previous = others.first(where: { $0.id == validated.id }),
           previous.sessionName != validated.sessionName,
           session(withID: previous.sessionName) != nil {
            try await service.renameSession(from: previous.sessionName, to: validated.sessionName)
        }
        try await mutateProjects { list in
            if let index = list.firstIndex(where: { $0.id == validated.id }) {
                list[index] = validated
            } else {
                list.append(validated)
            }
        }
        await refresh()
    }

    /// Quita el proyecto de Argos. NUNCA toca los archivos del servidor; si su sesión
    /// está corriendo, sigue viva (pasa a "sesión suelta").
    func removeProject(_ project: Project) async throws {
        try await mutateProjects { $0.removeAll { $0.id == project.id } }
        await refresh()
    }

    /// Importa sesiones sueltas como proyectos (carpeta = la de su primer panel).
    func importProjects(_ candidates: [Project]) async throws {
        try await mutateProjects { list in
            let existing = Set(list.map(\.sessionName))
            list += candidates.filter { !existing.contains($0.sessionName) }
        }
        await refresh()
    }

    /// Candidatos de importación para las sesiones sueltas (con su carpeta actual).
    func importCandidates() async throws -> [Project] {
        let paths = try await service.sessionFirstPanePaths()
        return projectListing.looseSessions.compactMap {
            ProjectListing.importCandidate(session: $0, path: paths[$0.name])
        }
    }

    // MARK: - Abrir / detener

    /// Abre el proyecto: si no corre, crea su sesión en la carpeta y lanza el comando de
    /// arranque. Si ya corre, no hace nada (la UI solo tiene que conectarse).
    func openProject(_ project: Project, defaultStartupCommand: String) async throws {
        guard session(withID: project.sessionName) == nil else { return }
        try await service.startProject(
            sessionName: project.sessionName,
            path: project.path,
            startupCommand: project.resolvedStartupCommand(default: defaultStartupCommand)
        )
        await refresh()
    }

    /// Detiene el proyecto (mata su sesión tmux). El proyecto se conserva.
    func stopProject(_ project: Project) async throws {
        try await service.stopSession(named: project.sessionName)
        await refresh()
    }

    /// Detiene varias sesiones (p. ej. todas las que corren en segundo plano).
    /// Devuelve las que fallaron.
    func stopSessions(named names: [String]) async -> [String] {
        var failed: [String] = []
        for name in names {
            do {
                try await service.stopSession(named: name)
            } catch {
                Log.store.error("Detener \(name, privacy: .public): \(error.userMessage, privacy: .public)")
                failed.append(name)
            }
        }
        await refresh()
        return failed
    }

    // MARK: - Persistencia

    /// Lee-modifica-escribe sobre la versión ACTUAL del servidor (otro Mac pudo
    /// cambiarla), para no pisar cambios ajenos con una copia vieja.
    private func mutateProjects(_ transform: (inout [Project]) -> Void) async throws {
        var fresh = try await service.loadProjects()
        transform(&fresh)
        try await service.saveProjects(fresh)
        projects = fresh
        projectsError = nil
    }
}
