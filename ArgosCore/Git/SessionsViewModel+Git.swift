//
//  SessionsViewModel+Git.swift
//  ArgosCore
//
//  Resumen git de los proyectos del servidor para la lista (insignia ↑2 ✎5) y para el
//  aviso «Claude terminó · N archivos cambiados». Un solo comando SSH para todos los
//  proyectos, como mucho cada `gitSummaryInterval` (o al momento si Claude terminó).
//

import Foundation

extension SessionsViewModel {

    /// Mínimo entre dos lecturas automáticas (git status de todos los proyectos).
    static let gitSummaryInterval: TimeInterval = 30

    /// Resumen de la carpeta de un proyecto (`nil` si no es repo o aún no se leyó).
    func gitSummary(for project: Project) -> GitRepoSummary? {
        gitSummaries[project.path]
    }

    /// Resumen de la carpeta del proyecto de una sesión (`nil` si es una sesión suelta).
    func gitSummary(forSession sessionName: String) -> GitRepoSummary? {
        project(forSession: sessionName).flatMap(gitSummary(for:))
    }

    /// Relee los resúmenes si toca (`force`: ya, p. ej. porque Claude acaba de terminar).
    /// Un fallo conserva lo último (es informativo; no debe molestar).
    func refreshGitSummaries(force: Bool = false, now: Date = Date()) async {
        guard case .loaded = state, !projects.isEmpty else { return }
        if !force, let last = lastGitSummaryRefresh,
           now.timeIntervalSince(last) < Self.gitSummaryInterval {
            return
        }
        lastGitSummaryRefresh = now
        let paths = Self.uniquePaths(of: projects)
        do {
            gitSummaries = try await service.gitSummaries(paths: paths)
        } catch {
            Log.ssh.notice("Resumen git de los proyectos: \(error.userMessage, privacy: .public)")
        }
    }

    /// Rutas de los proyectos sin repetir, en orden estable.
    nonisolated static func uniquePaths(of projects: [Project]) -> [String] {
        var seen = Set<String>()
        return projects.map(\.path).filter { seen.insert($0).inserted }
    }
}
