//
//  GitHubModels.swift
//  ArgosCore
//
//  Estado de GitHub de un repositorio del servidor (lógica pura): el PR de la rama
//  actual con sus checks y las ejecuciones de Actions del commit HEAD. Todo sale del
//  `gh` del SERVIDOR (Argos nunca guarda tokens de GitHub); lo parsea `GitHubParser`.
//

import Foundation

/// Estado agregado de un check o de una ejecución de CI.
enum GitHubCheckState: String, Sendable, Hashable, Comparable {
    case pending, success, failure, cancelled, skipped

    /// Orden de gravedad para agregar varios: un fallo manda sobre lo pendiente, etc.
    private var severity: Int {
        switch self {
        case .failure: return 4
        case .pending: return 3
        case .cancelled: return 2
        case .success: return 1
        case .skipped: return 0
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.severity < rhs.severity }

    var label: String {
        switch self {
        case .pending: return "En curso"
        case .success: return "Pasó"
        case .failure: return "Falló"
        case .cancelled: return "Cancelado"
        case .skipped: return "Omitido"
        }
    }

    /// Estado de un conjunto (`nil` si está vacío): el más grave, ignorando omitidos si hay más.
    static func aggregate(_ states: [GitHubCheckState]) -> GitHubCheckState? {
        let relevant = states.filter { $0 != .skipped }
        return (relevant.isEmpty ? states : relevant).max()
    }

    /// `status`/`conclusion` de Actions (`gh run list`: minúsculas) o de un CheckRun del
    /// rollup del PR (mayúsculas). Sin terminar → pendiente.
    static func from(status: String?, conclusion: String?) -> GitHubCheckState {
        guard status?.lowercased() == "completed" else { return .pending }
        switch conclusion?.lowercased() {
        case "success", "neutral": return .success
        case "skipped": return .skipped
        case "cancelled", "stale": return .cancelled
        default: return .failure  // failure, timed_out, startup_failure, action_required…
        }
    }

    /// `state` de un StatusContext (estados de commit clásicos).
    static func from(contextState: String?) -> GitHubCheckState {
        switch contextState?.uppercased() {
        case "SUCCESS": return .success
        case "PENDING", "EXPECTED": return .pending
        default: return .failure  // FAILURE, ERROR
        }
    }
}

/// Un check del PR (CheckRun de Actions o estado de commit de otro servicio).
struct GitHubCheck: Hashable, Sendable, Identifiable {
    let name: String
    /// Workflow de Actions (vacío en estados externos).
    let workflow: String
    let state: GitHubCheckState
    let url: URL?

    var id: String { "\(workflow)/\(name)" }
    var title: String { workflow.isEmpty ? name : "\(workflow) · \(name)" }
}

/// Pull request de la rama actual.
struct GitHubPullRequest: Hashable, Sendable {
    enum State: String, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }
    enum Review: String, Sendable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", required = "REVIEW_REQUIRED"
    }

    let number: Int
    let title: String
    let url: URL?
    let state: State
    let isDraft: Bool
    let review: Review?
    let checks: [GitHubCheck]

    var checksState: GitHubCheckState? { GitHubCheckState.aggregate(checks.map(\.state)) }

    var stateLabel: String {
        switch state {
        case .merged: return "Fusionado"
        case .closed: return "Cerrado"
        case .open: return isDraft ? "Borrador" : "Abierto"
        }
    }

    var reviewLabel: String? {
        switch review {
        case .approved: return "Aprobado"
        case .changesRequested: return "Piden cambios"
        case .required: return "Revisión pendiente"
        case nil: return nil
        }
    }
}

/// Una ejecución de GitHub Actions del commit HEAD.
struct GitHubRun: Hashable, Sendable, Identifiable {
    let id: Int
    let workflow: String
    let title: String
    let state: GitHubCheckState
    let url: URL?
    let event: String
    let createdAt: Date?
}

/// Todo lo que el panel muestra de GitHub para un repositorio.
struct GitHubSnapshot: Hashable, Sendable {
    /// Commit HEAD local (las ejecuciones son de este commit).
    let headSha: String
    let branch: String?
    /// `nil`: la rama no tiene PR (o HEAD está desacoplado).
    let pullRequest: GitHubPullRequest?
    /// Última ejecución de cada workflow para HEAD (vacío: aún no hay o no usa Actions).
    let runs: [GitHubRun]
    /// Fallo al leer las ejecuciones (el PR sí se pudo leer, o viceversa).
    let warning: String?

    var ciState: GitHubCheckState? { GitHubCheckState.aggregate(runs.map(\.state)) }
    var failedRuns: [GitHubRun] { runs.filter { $0.state == .failure } }
    /// Queda algún workflow en marcha (aunque otro ya haya fallado): el CI no ha terminado.
    var isCIRunning: Bool { runs.contains { $0.state == .pending } }
    var shortSha: String { String(headSha.prefix(7)) }
}

/// Resultado de consultar GitHub desde el servidor.
enum GitHubStatusResult: Hashable, Sendable {
    /// `gh` no está instalado en el servidor.
    case ghMissing
    /// `gh` no tiene sesión iniciada (`gh auth login` en el servidor).
    case notAuthenticated
    /// El repositorio no tiene un remoto de GitHub.
    case notGitHub
    case loaded(GitHubSnapshot)
    case failed(String)
}

/// Repositorio del usuario (para clonarlo como proyecto nuevo).
struct GitHubRepository: Hashable, Sendable, Identifiable {
    let nameWithOwner: String
    let description: String
    let isPrivate: Bool
    let updatedAt: Date?

    var id: String { nameWithOwner }
    /// Nombre de carpeta por defecto al clonar.
    var name: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }
}
