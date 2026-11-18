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
