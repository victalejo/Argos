//
//  CheckpointsModel.swift
//  ArgosCore
//
//  Estado de la hoja «Puntos de restauración» (Mac e iPhone/iPad): la lista de turnos,
//  qué cambió en el turno elegido (o desde entonces), el diff de un archivo y las
//  restauraciones con su confirmación. Los comandos van por `run` (SSH en la app, un
//  `sh` local en los tests).
//

import Foundation
import Observation

typealias CheckpointRunner = @Sendable (String) async throws -> CheckpointCommandOutput

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
        case .turn: return "Este turno"
        case .sinceThen: return "Hasta ahora"
        }
    }
}

enum CheckpointOperation: Equatable {
    case preview, restore, snapshot, toggle
    case restoreFile(String)
}

@MainActor
@Observable
final class CheckpointsModel {
    let path: String
    private let run: CheckpointRunner

    private(set) var state: CheckpointPanelState = .loading
    private(set) var selectedID: String?
    private(set) var comparison: CheckpointComparison = .turn
    private(set) var files: CheckpointFilesState = .none
    private(set) var selectedFile: String?
    private(set) var diffState: GitDiffState = .none
    private(set) var operation: CheckpointOperation?
    /// Restauración completa pendiente de confirmar (la UI muestra la lista de archivos).
    private(set) var pendingRestore: CheckpointRestorePreview?
    var notice: String?
    var errorMessage: String?

    private var filesRequest = 0
    private var diffRequest = 0

    init(path: String, run: @escaping CheckpointRunner) {
        self.path = path
        self.run = run
    }

    convenience init(path: String, service: any SSHServicing) {
        self.init(path: path) { command in try await service.runCheckpointCommand(command) }
    }

    // MARK: - Derivados

    var listing: CheckpointListing? {
        if case .loaded(let listing) = state { return listing }
        return nil
    }

    var checkpoints: [Checkpoint] { listing?.checkpoints ?? [] }

    var selected: Checkpoint? { checkpoints.first { $0.id == selectedID } }

    var isEnabledOnServer: Bool { listing?.state != .offServer }

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
    }

    private func loadFiles() async {
        guard let listing, let range = currentRange else { files = .none; return }
        filesRequest += 1
        let request = filesRequest
        files = .loading
        do {
            let command = CheckpointCommands.files(root: listing.root, from: range.from, to: range.to)
            let changes = try CheckpointParser.parseFiles(try await output(command))
            guard request == filesRequest else { return }
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

    /// Calcula qué cambiará y deja `pendingRestore` para que la UI pida confirmación.
    func prepareRestore(_ checkpoint: Checkpoint) async {
        guard operation == nil, let listing else { return }
        operation = .preview
        defer { operation = nil }
        do {
            let command = CheckpointCommands.preview(root: listing.root, commit: checkpoint.commit)
            let preview = try CheckpointParser.parsePreview(try await output(command), checkpoint: checkpoint)
            if preview.isEmpty {
                notice = "Los archivos ya están como en ese punto: no hay nada que restaurar."
            } else {
                pendingRestore = preview
            }
        } catch {
            report(error, "Vista previa de la restauración")
        }
    }

    func cancelRestore() { pendingRestore = nil }

    /// Restaura el punto confirmado. Si los archivos cambiaron desde la vista previa, no
    /// toca nada y vuelve a calcularla para que el usuario la revise.
    func confirmRestore() async {
        guard let preview = pendingRestore, let listing else { return }
        pendingRestore = nil
        let command = CheckpointCommands.restore(
            root: listing.root, commit: preview.checkpoint.commit, expectedTree: preview.currentTree, path: nil
        )
        let outcome = await perform(.restore, command)
        switch outcome {
        case .changed:
            errorMessage = "Los archivos cambiaron mientras revisabas la lista (¿sigue trabajando Claude?). "
                + "No se tocó nada: revisa la nueva lista."
            await prepareRestore(preview.checkpoint)
        case .done:
            notice = "Restaurado. Si te arrepientes, restaura el punto «Antes de restaurar…»."
        case .partial:
            notice = "Restaurado, pero quedan archivos distintos (p. ej. ignorados por git, que nunca se tocan)."
        case nil:
            break
        }
    }

    /// Deja un archivo como estaba en `checkpoint` (o lo borra si no existía y git no lo ignora).
    func restoreFile(_ path: String, from checkpoint: Checkpoint) async {
        guard let listing else { return }
        let command = CheckpointCommands.restore(root: listing.root, commit: checkpoint.commit, expectedTree: nil, path: path)
        if await perform(.restoreFile(path), command) != nil {
            notice = "«\((path as NSString).lastPathComponent)» restaurado. Antes se guardó un punto con el estado anterior."
        }
    }

    private func perform(_ op: CheckpointOperation, _ command: String) async -> CheckpointRestoreOutcome? {
        guard operation == nil else { return nil }
        operation = op
        var outcome: CheckpointRestoreOutcome?
        do {
            outcome = try CheckpointParser.parseRestore(try await output(command))
        } catch {
            report(error, "Restaurar")
        }
        operation = nil
        await reload()
        return outcome
    }

    // MARK: - Otras acciones

    func createSnapshot() async {
        guard operation == nil, let listing else { return }
        operation = .snapshot
        do {
            let created = try CheckpointParser.parseSnapshot(
                try await output(CheckpointCommands.snapshot(root: listing.root, label: "Punto creado a mano"))
            )
            notice = created == nil ? "No hay cambios desde el último punto." : "Punto de restauración creado."
        } catch {
            report(error, "Crear punto")
        }
        operation = nil
        await reload()
    }

    /// Activa o desactiva la captura en todo el servidor (lo respetan todos los dispositivos).
    func setEnabledOnServer(_ enabled: Bool) async {
        guard operation == nil else { return }
        operation = .toggle
        do {
            let text = try await output(CheckpointCommands.setServerEnabled(enabled))
            guard text.contains("ARGOS_CP_OK") else { throw CheckpointError.unexpectedOutput("") }
        } catch {
            report(error, "Activar puntos de restauración")
        }
        operation = nil
        await refresh()
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
            throw CheckpointError.failed(detail.isEmpty ? "código \(result.exitCode)" : String(detail.suffix(300)))
        }
        return result.stdout
    }

    private func report(_ error: Error, _ context: String) {
        errorMessage = error.userMessage
        Log.ssh.error("\(context, privacy: .public): \(error.userMessage, privacy: .public)")
    }
}
