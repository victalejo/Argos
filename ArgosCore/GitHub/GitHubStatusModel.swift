//
//  GitHubStatusModel.swift
//  ArgosCore
//
//  Sección «GitHub» del panel «Cambios» (Mac e iPhone/iPad): PR de la rama y CI del
//  commit HEAD, crear PR y relanzar lo fallido. Cada consulta toca la API de GitHub
//  (desde el servidor), así que se espacia: como mucho cada `refreshInterval`, o cada
//  `pendingInterval` mientras haya CI en curso.
//

import Foundation
import Observation

enum GitHubPanelState: Equatable {
    case idle
    case loading
    case ghMissing
    case notAuthenticated
    case notGitHub
    case loaded(GitHubSnapshot)
    case failed(String)
}

/// Operación de GitHub en curso.
enum GitHubOperation: Equatable {
    case createPullRequest
    case rerun(Int)
}

@MainActor
@Observable
final class GitHubStatusModel {
    let root: String
    private let service: any SSHServicing
    /// Se llama cuando hay CI en curso para HEAD (para avisar al terminar aunque se cierre el panel).
    private let onCIPending: (@MainActor (_ root: String, _ sha: String) -> Void)?

    private(set) var state: GitHubPanelState = .idle
    private(set) var operation: GitHubOperation?
    private(set) var lastRefresh: Date?
    /// Último resultado correcto (URL del PR creado…); la UI lo muestra y lo borra.
    var notice: String?
    var errorMessage: String?

    static let refreshInterval: TimeInterval = 60
    static let pendingInterval: TimeInterval = 20

    init(root: String, service: any SSHServicing,
         onCIPending: (@MainActor (_ root: String, _ sha: String) -> Void)? = nil) {
        self.root = root
        self.service = service
        self.onCIPending = onCIPending
    }

    var snapshot: GitHubSnapshot? {
        if case .loaded(let snapshot) = state { return snapshot }
        return nil
    }

    /// Se puede abrir un PR: hay rama, no tiene PR abierto y está subida y al día.
    func canCreatePullRequest(branch: GitBranchInfo) -> Bool {
        guard operation == nil, let snapshot, snapshot.branch != nil else { return false }
        if let pr = snapshot.pullRequest, pr.state == .open { return false }
        return branch.upstream != nil && !branch.upstreamGone && branch.ahead == 0
    }

    /// Intervalo hasta la próxima lectura automática.
    var currentInterval: TimeInterval {
        let pending = snapshot?.isCIRunning == true
            || snapshot?.pullRequest?.checks.contains { $0.state == .pending } == true
        return pending ? Self.pendingInterval : Self.refreshInterval
    }

    /// Relee si toca (`force`: ya, p. ej. al pulsar recargar o tras un push).
    func refresh(force: Bool = false, now: Date = Date()) async {
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < currentInterval { return }
        lastRefresh = now
        if snapshot == nil { state = .loading }
        do {
            switch try await service.gitHubStatus(root: root) {
            case .ghMissing: state = .ghMissing
            case .notAuthenticated: state = .notAuthenticated
            case .notGitHub: state = .notGitHub
            case .failed(let message):
                // Con datos ya visibles, un fallo pasajero (red) no los borra.
                if snapshot == nil { state = .failed(message) }
            case .loaded(let snapshot):
                state = .loaded(snapshot)
                if snapshot.isCIRunning { onCIPending?(root, snapshot.headSha) }
            }
        } catch {
            if snapshot == nil { state = .failed(error.userMessage) }
            Log.ssh.notice("gh status: \(error.userMessage, privacy: .public)")
        }
    }

    /// Bucle mientras la vista esté viva (cancelado por `.task`).
    func pollWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if operation == nil { await refresh() }
        }
    }

    func createPullRequest(draft: Bool = false) async {
        await perform(.createPullRequest) {
            let url = try await self.service.gitHubCreatePullRequest(root: self.root, draft: draft)
            return url.map { "PR creado: \($0.absoluteString)" } ?? "PR creado."
        }
    }

    func rerunFailed(_ run: GitHubRun) async {
        await perform(.rerun(run.id)) {
            try await self.service.gitHubRerunFailed(root: self.root, runID: run.id)
            return "Relanzados los jobs fallidos de «\(run.workflow)»."
        }
    }

    private func perform(_ op: GitHubOperation, _ body: () async throws -> String) async {
        guard operation == nil else { return }
        operation = op
        do {
            notice = try await body()
        } catch {
            errorMessage = error.userMessage
            Log.ssh.error("gh \(String(describing: op), privacy: .public): \(error.userMessage, privacy: .public)")
        }
        operation = nil
        await refresh(force: true)
    }
}
