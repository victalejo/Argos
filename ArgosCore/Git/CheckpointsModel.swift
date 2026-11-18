//
//  CheckpointsModel.swift
//  ArgosCore
//
//  Estado de la hoja «Puntos de restauración» (Mac e iPhone/iPad): activarlos en el
//  proyecto, la lista de turnos, qué cambió en el turno elegido (o desde entonces), el diff
//  de un archivo y las restauraciones con su confirmación. Los comandos van por `run` (SSH
//  en la app, un `sh` local en los tests) y el hook por `hooks`.
//

import Foundation
import Observation

typealias CheckpointRunner = @Sendable (String) async throws -> CheckpointCommandOutput

/// Instalación del hook de captura en el servidor (solo al activar la función).
struct CheckpointHookControl: Sendable {
    let isInstalled: @Sendable () async throws -> Bool
    let install: @Sendable () async throws -> Void
    let uninstall: @Sendable () async throws -> Void

    static func service(_ service: any SSHServicing) -> CheckpointHookControl {
        CheckpointHookControl(
            isInstalled: { try await service.checkpointHookInstalled() },
            install: { try await service.installCheckpointHook() },
            uninstall: { try await service.uninstallCheckpointHook() }
        )
    }
}

enum CheckpointPanelState: Equatable {
    case loading
    case gitMissing
    case notRepository
    case loaded(CheckpointListing)
    case failed(String)
}

enum CheckpointFilesState: Equatable {
    case none
    case loading
    case loaded([CheckpointFileChange])
    case failed(String)
}

/// Qué se compara del punto elegido.
enum CheckpointComparison: String, CaseIterable, Sendable {
    /// Hasta el punto siguiente (o hasta ahora, si es el último): lo que se hizo en el turno.
    case turn
    /// Hasta el estado actual: lo que se desharía al restaurar.
    case sinceThen

    var title: String {
        switch self {
        case .turn: return String(localized: "Este turno")
        case .sinceThen: return String(localized: "Hasta ahora")
        }
    }
}

enum CheckpointOperation: Equatable {
    case preview, restore, snapshot, settings
    case restoreFile(String)
}

/// Copia costosa pendiente de confirmar antes de la vista previa.
struct CheckpointHeavyPreview: Equatable {
    let checkpoint: Checkpoint
    let reason: String
}

@MainActor
@Observable
final class CheckpointsModel {
    let path: String
    private let run: CheckpointRunner
    private let hooks: CheckpointHookControl
    private let activity: @MainActor () -> ClaudeActivity?
    /// Interrumpe a Claude en la sesión del proyecto (Esc en sus paneles).
    private let stopClaude: (@MainActor () async throws -> Void)?

    private(set) var state: CheckpointPanelState = .loading
    private(set) var selectedID: String?
    private(set) var comparison: CheckpointComparison = .turn
    private(set) var files: CheckpointFilesState = .none
    private(set) var selectedFile: String?
    private(set) var diffState: GitDiffState = .none
    private(set) var operation: CheckpointOperation?
    /// Restauración completa pendiente de confirmar (la UI muestra la lista de archivos).
    private(set) var pendingRestore: CheckpointRestorePreview?
    /// La copia previa sería costosa: la UI pregunta antes de hacerla.
    private(set) var pendingHeavy: CheckpointHeavyPreview?
    var notice: String?
    var errorMessage: String?

    /// Árbol actual con el que se listaron los archivos en «Hasta ahora» (para comprobar
    /// que no cambió antes de restaurar uno).
    private var currentTree: String?
    private var filesRequest = 0
    private var diffRequest = 0

    init(path: String, run: @escaping CheckpointRunner, hooks: CheckpointHookControl,
         activity: @escaping @MainActor () -> ClaudeActivity? = { nil },
         stopClaude: (@MainActor () async throws -> Void)? = nil) {
        self.path = path
        self.run = run
        self.hooks = hooks
        self.activity = activity
        self.stopClaude = stopClaude
    }

    convenience init(path: String, service: any SSHServicing,
                     activity: @escaping @MainActor () -> ClaudeActivity? = { nil },
                     stopClaude: (@MainActor () async throws -> Void)? = nil) {
        self.init(path: path, run: { try await service.runCheckpointCommand($0) },
                  hooks: .service(service), activity: activity, stopClaude: stopClaude)
    }

    // MARK: - Derivados

    var listing: CheckpointListing? {
        if case .loaded(let listing) = state { return listing }
        return nil
    }

    var checkpoints: [Checkpoint] { listing?.checkpoints ?? [] }
    var selected: Checkpoint? { checkpoints.first { $0.id == selectedID } }
    var isEnabled: Bool { listing?.isEnabled ?? false }

    /// Claude está trabajando en el proyecto: no se restaura hasta que pare.
    var claudeIsWorking: Bool { activity() == .working }

    /// Se puede ofrecer «Detener a Claude y restaurar».
    var canStopClaude: Bool { stopClaude != nil }

    /// Plazo para que Claude deje de trabajar tras interrumpirlo.
    nonisolated static let stopTimeout: Duration = .seconds(20)

    /// Solo en «Hasta ahora» lo que se ve (punto → ahora) es lo que hace restaurar un archivo.
    var canRestoreFile: Bool { comparison == .sinceThen && operation == nil }

    /// Mensajes cuyo punto no se guardó durante el turno elegido.
    var skipsInSelectedTurn: [CheckpointSkip] {
        guard let listing, let index = checkpoints.firstIndex(where: { $0.id == selectedID }) else { return [] }
        return listing.skips(duringTurnAt: index)
    }

    /// Rango comparado (de, a) para el punto `index` de `checkpoints` (más reciente primero).
    nonisolated static func range(
        index: Int, in checkpoints: [Checkpoint], comparison: CheckpointComparison
    ) -> (from: String, to: String)? {
        guard checkpoints.indices.contains(index) else { return nil }
        let from = checkpoints[index].commit
        guard comparison == .turn, index > 0 else { return (from, CheckpointCommands.worktree) }
        return (from, checkpoints[index - 1].commit)
    }

    private var currentRange: (from: String, to: String)? {
        guard let index = checkpoints.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return Self.range(index: index, in: checkpoints, comparison: comparison)
    }

    // MARK: - Carga

    func refresh() async {
        do {
            switch try CheckpointParser.parseList(try await output(CheckpointCommands.list(path: path))) {
            case .gitMissing: state = .gitMissing
            case .notRepository: state = .notRepository
            case .listing(let listing): state = .loaded(listing)
            }
        } catch {
            if listing == nil { state = .failed(error.userMessage) }
            Log.ssh.error("Puntos de restauración: \(error.userMessage, privacy: .public)")
            return
        }
        if selected == nil {
            selectedID = nil
            files = .none
            clearFile()
        }
    }

    /// Abre el último turno («Ver lo que cambió en este turno»).
    func showLatestTurn() async {
        await refresh()
        comparison = .turn
        await select(checkpoints.first?.id)
    }

    func select(_ id: String?) async {
        selectedID = id
        clearFile()
        await loadFiles()
    }

    func setComparison(_ value: CheckpointComparison) async {
        guard value != comparison else { return }
        comparison = value
        await loadFiles()
        if let selectedFile { await selectFile(selectedFile) }
    }

    private func loadFiles() async {
        guard let listing, let range = currentRange else { files = .none; return }
        filesRequest += 1
        let request = filesRequest
        files = .loading
        do {
            let command = CheckpointCommands.files(root: listing.root, from: range.from, to: range.to)
            let text = try await output(command)
            let changes = try CheckpointParser.parseFiles(text)
            guard request == filesRequest else { return }
            currentTree = range.to == CheckpointCommands.worktree ? CheckpointParser.parseTrees(text)?.to : nil
            files = .loaded(changes)
            if let selectedFile, !changes.contains(where: { $0.path == selectedFile }) { clearFile() }
        } catch {
            guard request == filesRequest else { return }
            files = .failed(error.userMessage)
        }
    }

    func selectFile(_ path: String?) async {
        selectedFile = path
        diffState = .none
        guard let path, let listing, let range = currentRange else { return }
        diffRequest += 1
        let request = diffRequest
        diffState = .loading
        do {
            let command = CheckpointCommands.diff(root: listing.root, from: range.from, to: range.to, path: path)
            let text = try await output(command)
            // Las líneas de un diff empiezan por « », «+», «-», «@»…: nunca por un marcador.
            try CheckpointParser.throwIfFailed(text)
            guard request == diffRequest else { return }
            let truncated = text.utf8.count > GitCommands.diffByteLimit
            diffState = .loaded(GitDiffParser.parse(text, truncated: truncated))
        } catch {
            guard request == diffRequest else { return }
            diffState = .failed(error.userMessage)
        }
    }

    private func clearFile() {
        selectedFile = nil
        diffState = .none
    }

    // MARK: - Restaurar

    /// Calcula qué cambiará y deja `pendingRestore` para la confirmación. Sin `force`, si la
    /// copia del estado actual sería costosa, deja `pendingHeavy` y no la hace.
    func prepareRestore(_ checkpoint: Checkpoint, force: Bool = false) async {
        guard operation == nil, let listing else { return }
        pendingHeavy = nil
        operation = .preview
        defer { operation = nil }
        do {
            let command = CheckpointCommands.preview(root: listing.root, commit: checkpoint.commit, force: force)
            switch try CheckpointParser.parsePreview(try await output(command), checkpoint: checkpoint) {
            case .heavy(let reason):
                pendingHeavy = CheckpointHeavyPreview(checkpoint: checkpoint, reason: reason)
            case .ready(let preview) where preview.isEmpty && preview.issues.isEmpty:
                notice = String(localized: "Los archivos ya están como en ese punto: no hay nada que restaurar.")
            case .ready(let preview):
                pendingRestore = preview
            }
        } catch {
            report(error, "Vista previa de la restauración")
        }
    }

    func cancelHeavy() { pendingHeavy = nil }
    func cancelRestore() { pendingRestore = nil }

    /// Restaura el punto confirmado (nunca con Claude trabajando). Si los archivos
    /// cambiaron desde la vista previa, no toca nada y la vuelve a calcular.
    func confirmRestore() async {
        guard let preview = pendingRestore, let listing, preview.canRestore else { return }
        guard !claudeIsWorking else {
            errorMessage = CheckpointTexts.workingWarning
            return
        }
        pendingRestore = nil
        let command = CheckpointCommands.restore(
            root: listing.root, commit: preview.checkpoint.commit, expectedTree: preview.currentTree, path: nil
        )
        let outcome = await perform(.restore, command)
        if outcome == .changed {
            errorMessage = String(localized: "Los archivos cambiaron mientras revisabas la lista (¿sigue trabajando Claude?). No se tocó nada: revisa la nueva lista.")
            await prepareRestore(preview.checkpoint)
        }
    }

    /// Deja un archivo como estaba en el punto elegido, solo en «Hasta ahora» (lo que se ve
    /// es lo que se hace) y si nada cambió desde que se listó.
    func restoreFile(_ path: String) async {
        guard canRestoreFile, let listing, let checkpoint = selected else { return }
        guard !claudeIsWorking else {
            errorMessage = CheckpointTexts.workingWarning
            return
        }
        let command = CheckpointCommands.restore(
            root: listing.root, commit: checkpoint.commit, expectedTree: currentTree, path: path
        )
        if await perform(.restoreFile(path), command) == .changed {
            errorMessage = String(localized: "Los archivos cambiaron desde que los miraste: revisa el diff y vuelve a intentarlo.")
        }
    }

    /// «Detener a Claude y restaurar»: lo interrumpe, espera a que pare y restaura.
    func stopClaudeAndRestore(file path: String? = nil) async {
        guard await stopClaudeAndWait() else { return }
        if let path { await restoreFile(path) } else { await confirmRestore() }
    }

    private func stopClaudeAndWait() async -> Bool {
        guard let stopClaude else { return !claudeIsWorking }
        do {
            try await stopClaude()
        } catch {
            report(error, "Detener a Claude")
            return false
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.stopTimeout)
        while claudeIsWorking, clock.now < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        if claudeIsWorking {
            errorMessage = String(localized: "Claude sigue trabajando. Espera a que termine o detenlo en su terminal y vuelve a intentarlo.")
            return false
        }
        return true
    }

    private func perform(_ op: CheckpointOperation, _ command: String) async -> CheckpointRestoreOutcome? {
        guard operation == nil else { return nil }
        operation = op
        var outcome: CheckpointRestoreOutcome?
        do {
            outcome = try CheckpointParser.parseRestore(try await output(command))
            if let outcome { announce(outcome, file: op) }
        } catch {
            report(error, "Restaurar")
        }
        operation = nil
        await reload()
        return outcome
    }

    private func announce(_ outcome: CheckpointRestoreOutcome, file op: CheckpointOperation) {
        switch outcome {
        case .done:
            if case .restoreFile(let path) = op {
                notice = String(localized: "«\((path as NSString).lastPathComponent)» restaurado. Antes se guardó un punto con el estado anterior.")
            } else {
                notice = String(localized: "Restaurado. Si te arrepientes, restaura el punto «Antes de restaurar…».")
            }
        case .partial(_, let skipped) where skipped.contains(where: \.isConflict):
            errorMessage = CheckpointTexts.partialMessage(skipped)
        case .partial:
            notice = String(localized: "Restaurado, salvo archivos que git ignora o repositorios anidados, que nunca se tocan.")
        case .conflict(let issues):
            errorMessage = CheckpointTexts.conflictMessage(issues)
        case .nothing(let reason):
            notice = reason
        case .changed:
            break
        }
    }

    // MARK: - Ajustes y otras acciones

    /// Activa la captura en el proyecto (instala el hook en el servidor si hace falta) o la
    /// desactiva, borrando sus puntos.
    func setEnabled(_ enabled: Bool) async {
        guard let listing else { return }
        await performSettings(enabled ? "Activar puntos de restauración" : "Desactivar puntos de restauración") {
            if enabled {
                let installed = try await self.hooks.isInstalled()
                if !installed { try await self.hooks.install() }
            }
            let command = enabled ? CheckpointCommands.enable(root: listing.root) : CheckpointCommands.disable(root: listing.root)
            try await self.expectOK(command)
        }
    }

    func setStoresPrompts(_ enabled: Bool) async {
        guard let listing else { return }
        await performSettings("Guardar extractos") {
            try await self.expectOK(CheckpointCommands.storePrompts(root: listing.root, enabled))
        }
    }

    /// Borra todos los puntos del proyecto (sigue activado).
    func purgeAll() async {
        guard let listing else { return }
        await performSettings("Borrar puntos") {
            try await self.expectOK(CheckpointCommands.purge(root: listing.root))
            self.notice = String(localized: "Se borraron todos los puntos de este proyecto.")
        }
    }

    /// Desactiva el proyecto y quita el hook y su script del servidor.
    func removeFromServer() async {
        guard let listing else { return }
        await performSettings("Quitar del servidor") {
            try await self.expectOK(CheckpointCommands.disable(root: listing.root))
            try await self.hooks.uninstall()
            self.notice = String(localized: "Hook de captura quitado del servidor. Los demás proyectos dejan de guardar puntos.")
        }
    }

    func createSnapshot() async {
        guard operation == nil, let listing else { return }
        operation = .snapshot
        do {
            let created = try CheckpointParser.parseSnapshot(
                try await output(CheckpointCommands.snapshot(root: listing.root, label: "Punto creado a mano"))
            )
            notice = created == nil ? String(localized: "No hay cambios desde el último punto.") : String(localized: "Punto de restauración creado.")
        } catch {
            report(error, "Crear punto")
        }
        operation = nil
        await reload()
    }

    private func performSettings(_ context: String, _ body: () async throws -> Void) async {
        guard operation == nil else { return }
        operation = .settings
        do { try await body() } catch { report(error, context) }
        operation = nil
        selectedID = nil
        await refresh()
    }

    private func expectOK(_ command: String) async throws {
        let text = try await output(command)
        try CheckpointParser.throwIfFailed(text)
        guard text.contains("ARGOS_CP_OK") else { throw CheckpointError.unexpectedOutput("") }
    }

    private func reload() async {
        await refresh()
        await loadFiles()
        if let selectedFile { await selectFile(selectedFile) }
    }

    // MARK: - Utilidades

    /// Ejecuta y devuelve stdout; los marcadores de error los interpreta el parser.
    private func output(_ command: String) async throws -> String {
        let result = try await run(command)
        if result.exitCode != 0, !result.stdout.contains("ARGOS_CP_") {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CheckpointError.failed(detail.isEmpty ? String(localized: "código \(String(result.exitCode))") : String(detail.suffix(300)))
        }
        return result.stdout
    }

    private func report(_ error: Error, _ context: String) {
        errorMessage = error.userMessage
        Log.ssh.error("\(context, privacy: .public): \(error.userMessage, privacy: .public)")
    }
}
