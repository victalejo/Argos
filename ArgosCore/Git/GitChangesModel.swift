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

    /// El commit está en pausa porque lo que se iba a commitear cambió desde que se vio:
    /// la UI pide confirmación con este texto (`confirmCommit` / `cancelCommit`).
    private(set) var commitReview: String?

    private var isRefreshing = false
    private var diffRequest = 0
    /// Huella (`GitFingerprint`) del diff que se está mostrando, y de cada diff que el
    /// usuario ha visto (por ruta), para detectar que cambiaron por debajo.
    private var shownFingerprint: (path: String, value: String)?
    private var viewedFingerprints: [String: String] = [:]

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
        } else if await selectedDiffIsStale() {
            await loadDiff()
        }
    }

    /// ¿Cambió el contenido del archivo seleccionado desde que se cargó su diff? (el
    /// estado git no lo dice: un archivo sigue «M» aunque Claude lo siga editando).
    private func selectedDiffIsStale() async -> Bool {
        guard let change = selectedChange, let status, let shown = shownFingerprint,
              shown.path == change.path else { return false }
        guard let current = await fingerprint(of: change, in: status) else { return false }
        return current != shown.value
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

    /// Selecciona un archivo y carga su diff. Volver a pulsar el seleccionado lo recarga.
    func select(_ path: String?) async {
        guard path != selectedPath || path != nil else { return }
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
            // La huella ANTES del diff: si el archivo cambia entre medias, el próximo
            // sondeo verá otra huella y recargará (al revés se perdería el cambio).
            let fingerprint = await fingerprint(of: change, in: status)
            let diff = try await service.gitDiff(
                root: status.root, change: change, hasCommits: status.branch.hasCommits
            )
            guard request == diffRequest else { return }
            diffState = .loaded(diff)
            shownFingerprint = fingerprint.map { (change.path, $0) }
            if let fingerprint { viewedFingerprints[change.path] = fingerprint }
        } catch {
            guard request == diffRequest else { return }
            diffState = .failed(error.userMessage)
        }
    }

    private func fingerprint(of change: GitFileChange, in status: GitRepositoryStatus) async -> String? {
        do {
            return try await service.gitFingerprints(
                root: status.root, changes: [change], hasCommits: status.branch.hasCommits
            ).first
        } catch {
            Log.ssh.error("Huella del diff: \(error.userMessage, privacy: .public)")
            return nil
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

    /// Commit de los archivos marcados. Antes relee el estado: si lo que se va a
    /// commitear no es lo que se veía (archivos nuevos o quitados, o un diff ya revisado
    /// que cambió), no lo hace y deja `commitReview` para que la UI pida confirmación.
    func commit() async {
        guard canCommit, let shown = status else { return }
        let shownIncluded = Self.includedChanges(shown.changes, excluded: excludedPaths)
        operation = .commit
        let review = await reviewBeforeCommit(shownIncluded: shownIncluded)
        operation = nil
        if let review {
            commitReview = review
            await loadDiff()
            return
        }
        await performCommit()
    }

    /// Hace el commit aunque haya cambiado lo que se veía (tras `commitReview`).
    func confirmCommit() async {
        commitReview = nil
        await performCommit()
    }

    func cancelCommit() { commitReview = nil }

    /// Motivo para pedir confirmación, o `nil` si lo que se va a commitear es lo visto.
    private func reviewBeforeCommit(shownIncluded: [GitFileChange]) async -> String? {
        let fresh: GitRepositoryStatus
        do {
            guard case .repository(let status) = try await service.gitStatus(at: path) else { return nil }
            fresh = status
        } catch {
            Log.ssh.error("git status antes del commit: \(error.userMessage, privacy: .public)")
            return nil
        }
        apply(fresh)
        let included = Self.includedChanges(fresh.changes, excluded: excludedPaths)
        let viewed = included.filter { viewedFingerprints[$0.path] != nil }
        var current: [String] = []
        if !viewed.isEmpty {
            do {
                current = try await service.gitFingerprints(
                    root: fresh.root, changes: viewed, hasCommits: fresh.branch.hasCommits
                )
            } catch {
                Log.ssh.error("Huellas antes del commit: \(error.userMessage, privacy: .public)")
            }
        }
        let changedPaths = zip(viewed, current).compactMap { change, value in
            viewedFingerprints[change.path] == value ? nil : change.path
        }
        return Self.commitReviewMessage(shown: shownIncluded, current: included, changedDiffs: changedPaths)
    }

    /// Texto del aviso (lógica pura): archivos que entran o salen y diffs revisados que
    /// cambiaron. `nil` si no hay diferencias.
    nonisolated static func commitReviewMessage(
        shown: [GitFileChange], current: [GitFileChange], changedDiffs: [String]
    ) -> String? {
        let before = Set(shown.map(\.path)), after = Set(current.map(\.path))
        var parts: [String] = []
        let added = after.subtracting(before).count
        let removed = before.subtracting(after).count
        if added > 0 { parts.append(added == 1 ? "hay 1 archivo nuevo" : "hay \(added) archivos nuevos") }
        if removed > 0 { parts.append(removed == 1 ? "1 archivo ya no tiene cambios" : "\(removed) archivos ya no tienen cambios") }
        if Set(shown) != Set(current), added == 0, removed == 0 { parts.append("cambió el estado de algún archivo") }
        if !changedDiffs.isEmpty {
            let names = changedDiffs.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let more = changedDiffs.count > 3 ? " y \(changedDiffs.count - 3) más" : ""
            parts.append("cambió el contenido de \(names)\(more) desde que lo revisaste")
        }
        guard !parts.isEmpty else { return nil }
        return "Desde que miraste los cambios, " + parts.joined(separator: "; ")
            + ". Revisa la lista antes de hacer el commit o hazlo igualmente."
    }

    private func performCommit() async {
        guard canCommit, let status else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let included = Self.includedChanges(status.changes, excluded: excludedPaths)
        let committed = await perform(.commit) {
            let summary = try await self.service.gitCommit(root: status.root, message: message, changes: included)
            return Self.firstLine(summary) ?? "Commit hecho."
        }
        if committed {
            commitMessage = ""
            viewedFingerprints = [:]
        }
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
