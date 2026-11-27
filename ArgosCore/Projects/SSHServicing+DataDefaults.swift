//
//  SSHServicing+DataDefaults.swift
//  Argos
//
//  Implementaciones por defecto de los requisitos de «datos seguros» para dobles de
//  prueba que solo modelan `loadProjects`/`saveProjects`/`uploadSyncFile`. `SSHService`
//  implementa todos estos requisitos por su cuenta (escritura con huella, envío atómico).
//

import Foundation

extension SSHServicing {
    func loadProjectsReport() async throws -> ProjectsLoadReport {
        ProjectsLoadReport(projects: try await loadProjects())
    }

    func updateProjects(
        _ transform: @escaping @Sendable ([Project]) throws -> [Project]
    ) async throws -> ProjectsLoadReport {
        let updated = try transform(try await loadProjects())
        try await saveProjects(updated)
        return ProjectsLoadReport(projects: updated)
    }

    /// Dobles sin documento: se parte de los proyectos y solo se guardan los proyectos.
    func updateProjectsDocument(
        _ transform: @escaping @Sendable (ProjectsDocument) throws -> ProjectsDocument
    ) async throws -> ProjectsLoadReport {
        let base = try ProjectsDocument.empty.replacingProjects(try await loadProjects())
        let updated = try transform(base)
        try await saveProjects(updated.projects)
        return ProjectsLoadReport(document: updated)
    }

    func promptVariableValues(projectPath: String) async throws -> PromptVariables.Values {
        PromptVariables.Values()
    }

    func pastePromptToTerminal(session: String, window: Int?, text: String) async throws {
        try await sendKeys(session: session, keys: text, enter: true)
    }

    func restoreProjectsBackup() async throws -> ProjectsLoadReport {
        throw ProjectError.noBackup
    }

    func stageSyncFile(root: String, file: SyncFile, from localURL: URL) async throws {
        try await uploadSyncFile(root: root, file: file, from: localURL)
    }

    func placeStagedSyncFiles(root: String, files: [SyncFile]) async throws {}
    func discardStagedSyncFiles(root: String, paths: [String]) async throws {}
    func removeStaleSyncTemporaries(root: String) async throws {}
}
