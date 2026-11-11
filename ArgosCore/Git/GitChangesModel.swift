//
//  GitChangesModel.swift
//  ArgosCore
//
//  Estado del panel «Cambios» de un proyecto (Mac e iPhone/iPad): estado git, archivo
//  seleccionado y su diff, qué archivos entran en el commit y las operaciones
//  (descartar, commit, push, pull). La red va por `SSHServicing`.
//

import Foundation
import Observation

enum GitPanelState: Equatable {
    case loading
    case gitMissing
    case notRepository
    case loaded(GitRepositoryStatus)
    case failed(String)
}

enum GitDiffState: Equatable {
    case none
    case loading
    case loaded(GitFileDiff)
    case failed(String)
}

/// Operación en curso (deshabilita los botones y muestra progreso).
enum GitOperation: Equatable {
    case commit, push, pull
    /// Claude está proponiendo el mensaje del commit.
    case suggest
    case discard(String)
}

@MainActor
@Observable
final class GitChangesModel {
    let path: String
    private let service: any SSHServicing
    /// Tras un push correcto (raíz del repo): para vigilar su CI y avisar al terminar.
    private let onPushed: (@MainActor (String) -> Void)?

    private(set) var state: GitPanelState = .loading
    private(set) var selectedPath: String?
    private(set) var diffState: GitDiffState = .none
    /// Archivos que el usuario desmarcó del próximo commit (por defecto entran todos).
    private(set) var excludedPaths: Set<String> = []
    private(set) var operation: GitOperation?
    var commitMessage = ""
    /// Último resultado correcto (p. ej. el resumen del commit); la UI lo muestra y lo borra.
    var notice: String?
    /// Último fallo de una operación; la UI lo muestra en una alerta y lo borra.
    var errorMessage: String?

    private var isRefreshing = false
    private var diffRequest = 0

    /// Intervalo del refresco automático mientras el panel está visible: el agente puede
    /// estar editando archivos a la vez.
    static let pollInterval: Duration = .seconds(5)

    init(path: String, service: any SSHServicing, onPushed: (@MainActor (String) -> Void)? = nil) {
        self.path = path
        self.service = service
        self.onPushed = onPushed
    }

    // MARK: - Derivados

    var status: GitRepositoryStatus? {
        if case .loaded(let status) = state { return status }
        return nil
    }

    var changes: [GitFileChange] { status?.changes ?? [] }

    var selectedChange: GitFileChange? {
        guard let selectedPath else { return nil }
        return changes.first { $0.path == selectedPath }
    }

    func isIncluded(_ change: GitFileChange) -> Bool { !excludedPaths.contains(change.path) }

    var includedCount: Int { changes.filter(isIncluded).count }

    var hasConflicts: Bool { changes.contains(where: \.isConflicted) }

    var canCommit: Bool {
        operation == nil && !hasConflicts && includedCount > 0
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canPush: Bool {
        guard operation == nil, let branch = status?.branch, branch.name != nil, branch.hasCommits else {
            return false
        }
        return branch.upstream == nil || branch.ahead > 0
    }

    var canPull: Bool {
        guard operation == nil, let branch = status?.branch else { return false }
        return branch.upstream != nil && !branch.upstreamGone
    }

    /// Archivos que entran en el commit (los no desmarcados), lógica pura.
    nonisolated static func includedChanges(_ changes: [GitFileChange], excluded: Set<String>) -> [GitFileChange] {
        changes.filter { !excluded.contains($0.path) }
    }

    // MARK: - Carga

    /// Vuelve a leer el estado. `reloadDiff`: recarga también el diff seleccionado (el
    /// refresco automático no lo hace para no traer el diff entero cada pocos segundos,
    /// salvo que cambie el estado del archivo).
    func refresh(reloadDiff: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let previous = selectedChange
        do {
            switch try await service.gitStatus(at: path) {
            case .gitMissing: state = .gitMissing
            case .notRepository: state = .notRepository
            case .repository(let status): apply(status)
            }
        } catch {
            // Un fallo del refresco automático no borra lo que ya se ve.
            if status == nil { state = .failed(error.userMessage) }
            Log.ssh.error("git status: \(error.userMessage, privacy: .public)")
            return
        }
        let current = selectedChange
        if current == nil {
            selectedPath = nil
            diffState = .none
        } else if reloadDiff || current != previous {
            await loadDiff()
        }
    }

    private func apply(_ status: GitRepositoryStatus) {
        state = .loaded(status)
        let paths = Set(status.changes.map(\.path))
        excludedPaths = excludedPaths.intersection(paths)
    }

    /// Bucle de refresco mientras la vista esté viva (cancelado por `.task`).
    func pollWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            if operation == nil { await refresh(reloadDiff: false) }
        }
    }

    // MARK: - Selección y diff

    func select(_ path: String?) async {
        guard path != selectedPath else { return }
        selectedPath = path
        await loadDiff()
    }

    private func loadDiff() async {
        guard let change = selectedChange, let status else {
            diffState = .none
            return
        }
        diffRequest += 1
        let request = diffRequest
        if case .loaded = diffState {} else { diffState = .loading }
        do {
            let diff = try await service.gitDiff(
                root: status.root, change: change, hasCommits: status.branch.hasCommits
            )
            guard request == diffRequest else { return }
            diffState = .loaded(diff)
        } catch {
            guard request == diffRequest else { return }
            diffState = .failed(error.userMessage)
        }
    }

    // MARK: - Selección para el commit

    func setIncluded(_ included: Bool, for change: GitFileChange) {
        if included { excludedPaths.remove(change.path) } else { excludedPaths.insert(change.path) }
    }

    func setAllIncluded(_ included: Bool) {
        excludedPaths = included ? [] : Set(changes.map(\.path))
    }

    // MARK: - Operaciones

    func discard(_ change: GitFileChange) async {
        guard let status, status.branch.hasCommits || change.isUntracked else {
            errorMessage = "No se puede descartar en un repositorio sin commits."
            return
        }
        await perform(.discard(change.path)) {
            try await self.service.gitDiscard(root: status.root, change: change)
            return nil
        }
    }

    /// Hay archivos marcados y nada en curso: Claude puede proponer el mensaje.
    var canSuggestMessage: Bool { operation == nil && includedCount > 0 }

    /// Pide a Claude Code (en el servidor) un mensaje para los archivos marcados, con el
    /// estilo de los commits recientes del repo. Sustituye lo escrito en el campo.
    func suggestCommitMessage(oauthToken: String? = KeychainStore.claudeOAuthToken()) async {
        guard canSuggestMessage, let status else { return }
        let included = Self.includedChanges(status.changes, excluded: excludedPaths)
        operation = .suggest
        defer { operation = nil }
        do {
            commitMessage = try await CommitMessageSuggestion.suggest(
                service: service, root: status.root, changes: included,
                hasCommits: status.branch.hasCommits, oauthToken: oauthToken
            )
        } catch {
            errorMessage = error.userMessage
            Log.ssh.error("Sugerir mensaje de commit: \(error.userMessage, privacy: .public)")
        }
    }

    func commit() async {
        guard canCommit, let status else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let included = Self.includedChanges(status.changes, excluded: excludedPaths)
        let committed = await perform(.commit) {
            let summary = try await self.service.gitCommit(root: status.root, message: message, changes: included)
            return Self.firstLine(summary) ?? "Commit hecho."
        }
        if committed { commitMessage = "" }
    }

    func push() async {
        guard canPush, let status else { return }
        let pushed = await perform(.push) {
            _ = try await self.service.gitPush(root: status.root, hasUpstream: status.branch.upstream != nil)
            return "Cambios subidos a \(status.branch.upstream ?? "origin")."
        }
        if pushed { onPushed?(status.root) }
    }

    func pull() async {
        guard canPull, let status else { return }
        await perform(.pull) {
            let output = try await self.service.gitPull(root: status.root)
            return Self.firstLine(output) ?? "Rama actualizada."
        }
    }

    /// Ejecuta una operación, publica su resultado y refresca. Devuelve si tuvo éxito.
    @discardableResult
    private func perform(_ op: GitOperation, _ body: () async throws -> String?) async -> Bool {
        guard operation == nil else { return false }
        operation = op
        var succeeded = false
        do {
            notice = try await body()
            succeeded = true
        } catch {
            errorMessage = error.userMessage
            Log.ssh.error("git \(String(describing: op), privacy: .public): \(error.userMessage, privacy: .public)")
        }
        operation = nil
        await refresh()
        return succeeded
    }

    nonisolated static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
