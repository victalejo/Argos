//
//  PromptLibraryModel.swift
//  ArgosCore
//
//  Pantalla «Biblioteca de encargos» de un proyecto (Mac e iPhone/iPad): los prompts del
//  proyecto y los comunes del servidor; crear, editar, borrar y reordenar; y usarlos ya
//  (pegar en la terminal o añadir a la cola de encargos). Cada cambio se aplica sobre el
//  projects.json recién leído (`updateProjectsDocument`), así no pisa a otro dispositivo.
//

import Foundation
import Observation

@MainActor
@Observable
final class PromptLibraryModel {

    private(set) var library: PromptLibrary
    private(set) var isLoading = true
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var notice: String?

    /// Texto ya relleno con lo que dice git, esperando a que se confirme antes de enviarlo.
    var pendingUse: PendingPromptUse?

    /// Prompt en edición (nuevo o existente) y dónde se guarda.
    var editing: SavedPrompt?
    var editingScope: PromptScope = .common

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored let project: Project
    @ObservationIgnored let claudeWindows: [Int: ClaudeActivity]
    /// Avisa al resto de la app (p. ej. `SessionsViewModel`) del projects.json nuevo.
    @ObservationIgnored private let onReport: (ProjectsLoadReport) -> Void

    init(
        service: any SSHServicing,
        project: Project,
        library: PromptLibrary,
        claudeWindows: [Int: ClaudeActivity],
        onReport: @escaping (ProjectsLoadReport) -> Void = { _ in }
    ) {
        self.service = service
        self.project = project
        self.library = library
        self.claudeWindows = claudeWindows
        self.onReport = onReport
    }

    var projectPrompts: [SavedPrompt] { library.projectPrompts(project.id) }
    var commonPrompts: [SavedPrompt] { library.visibleCommon }

    /// Lee la biblioteca y, la primera vez en el servidor, siembra los ejemplos.
    func load() async {
        await perform {
            let report = try await ConnectionPriority.background { try await self.service.loadProjectsReport() }
            self.accept(report)
            if !report.prompts.seeded && report.fileVersion <= ProjectsDocument.supportedVersion {
                self.accept(try await self.service.updateProjectsDocument { try $0.seedingExamplesIfNeeded() })
            }
        }
        isLoading = false
    }

    // MARK: - Edición

    func startNew(scope: PromptScope) {
        editingScope = scope
        editing = SavedPrompt(title: "", text: "")
    }

    func startEditing(_ prompt: SavedPrompt, scope: PromptScope) {
        editingScope = scope
        editing = prompt
    }

    static func canSave(_ prompt: SavedPrompt) -> Bool {
        !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && prompt.text.count <= SavedPrompt.maxTextLength
    }

    func saveEditing() async {
        guard var prompt = editing, Self.canSave(prompt) else { return }
        prompt.title = String(PromptText.singleLine(prompt.title).prefix(SavedPrompt.maxTitleLength))
        prompt.text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = editingScope
        let saved = prompt
        await change(scope) { $0.upserting(saved) }
        if errorMessage == nil { editing = nil }
    }

    func delete(_ prompt: SavedPrompt, scope: PromptScope) async {
        let id = prompt.id
        await change(scope) { $0.removing(id: id) }
    }

    func move(scope: PromptScope, from source: IndexSet, to destination: Int) async {
        let order = Self.moving((scope == .common ? commonPrompts : projectPrompts).map(\.id), from: source, to: destination)
        await change(scope) { $0.reordered(order) }
    }

    /// Como `move(fromOffsets:toOffset:)` de SwiftUI (que el núcleo no puede importar).
    nonisolated static func moving(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        let moved = source.sorted().filter { $0 < ids.count }.map { ids[$0] }
        let before = source.filter { $0 < destination }.count
        var rest = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moved, at: min(max(0, destination - before), rest.count))
        return rest
    }

    /// Cambia una lista sembrando antes (si hacía falta): los ejemplos que se ven antes de
    /// sembrar tienen que existir para poder editarlos, borrarlos o moverlos.
    private func change(_ scope: PromptScope, _ transform: @escaping @Sendable (PromptList) -> PromptList) async {
        await perform {
            self.accept(try await self.service.updateProjectsDocument { document in
                try document.seedingExamplesIfNeeded().updatingPrompts(scope) { transform($0) }
            })
        }
    }

    // MARK: - Usar un prompt

    /// Pega el prompt en la terminal del proyecto. Con variables, antes se enseña el texto
    /// ya relleno para confirmarlo (`pendingUse`).
    func sendToTerminal(_ prompt: SavedPrompt) async {
        await use(prompt, .send)
    }

    /// Añade el prompt a la cola de encargos del proyecto (en la terminal). Con variables,
    /// antes se confirma el texto relleno.
    func enqueue(_ prompt: SavedPrompt) async {
        await use(prompt, .enqueue)
    }

    /// Envía el texto que se acaba de confirmar, tal cual se enseñó (no se vuelve a leer git).
    func confirmPendingUse() async {
        guard let pending = pendingUse else { return }
        pendingUse = nil
        await perform { try await self.run(pending.kind, prompt: pending.prompt, text: pending.text) }
    }

    func cancelPendingUse() {
        pendingUse = nil
    }

    private func use(_ prompt: SavedPrompt, _ kind: PendingPromptUse.Kind) async {
        guard PromptVariables.containsVariables(prompt.text) else {
            await perform { try await self.run(kind, prompt: prompt, text: prompt.text) }
            return
        }
        await perform {
            let text = await PromptExpansion.expand(prompt.text, service: self.service, projectPath: self.project.path)
            self.pendingUse = PendingPromptUse(prompt: prompt, kind: kind, text: text)
        }
    }

    private func run(_ kind: PendingPromptUse.Kind, prompt: SavedPrompt, text: String) async throws {
        switch kind {
        case .send:
            try await service.pastePromptToTerminal(session: project.sessionName, window: preferredWindow, text: text)
            notice = String(localized: "«\(prompt.displayTitle)» enviado a la terminal.")
        case .enqueue:
            let request = ClaudeTaskRequest(
                prompt: text, session: project.sessionName,
                window: ClaudeTasksModel.suggestedWindow(claudeWindows), cleanContext: false, commit: false
            )
            try await service.enqueueTask(request, projectPath: project.path)
            notice = String(localized: "«\(prompt.displayTitle)» se ha añadido a la cola de encargos.")
        }
    }

    private var preferredWindow: Int? { Self.pasteWindow(claudeWindows) }

    /// Ventana donde pegar: SOLO una con Claude libre (`done`), la de número más bajo. Si
    /// ninguna lo está (o no hay estado conocido), la activa: el script vuelve a mirar
    /// justo antes de pegar y no pega si Claude trabaja o espera un permiso (el Enter
    /// elegiría «Sí»). Nunca se propone una ventana `working`/`waiting`.
    nonisolated static func pasteWindow(_ windows: [Int: ClaudeActivity]) -> Int? {
        windows.filter { $0.value == .done }.keys.min()
    }

    // MARK: - Interno

    private func accept(_ report: ProjectsLoadReport) {
        library = report.prompts
        onReport(report)
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }
        do {
            try await action()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            Log.store.error("Biblioteca de encargos: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
    }
}

/// Un uso de un prompt con variables a la espera de confirmación: el texto exacto que se
/// enviará, ya relleno con lo que dijo git.
struct PendingPromptUse: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case send, enqueue }

    let id = UUID()
    let prompt: SavedPrompt
    let kind: Kind
    let text: String
}
