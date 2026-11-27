//
//  SavedPromptEntity.swift
//  ArgosiOS
//
//  Encargos guardados de la biblioteca tal como los ven Atajos y Siri: de la caché del
//  dispositivo (`SavedPromptShortcutCache`, solo títulos), filtrados por el proyecto del
//  atajo. Con el bloqueo de Argos activo, las sugerencias quedan vacías igual que las de
//  proyectos (`ShortcutExposure`); el texto se lee del servidor al ejecutar.
//

import AppIntents
import Foundation

struct SavedPromptEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Encargo guardado" }
    static var defaultQuery: SavedPromptEntityQuery { SavedPromptEntityQuery() }

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(_ prompt: CachedPrompt) {
        id = prompt.id
        title = prompt.title
    }
}

struct SavedPromptEntityQuery: EntityStringQuery {
    @IntentParameterDependency<AskClaudeIntent>(\.$project)
    var intent

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SavedPromptEntity] {
        let cache = SavedPromptShortcutCacheStore().load()
        let own = projectPrompts(cache)
        return identifiers.compactMap { id in
            (own.first { $0.id == id } ?? cache.prompt(withID: id)).map(SavedPromptEntity.init)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SavedPromptEntity] {
        let needle = ProjectShortcutCache.folded(string)
        guard !needle.isEmpty || ShortcutExposure.showsSuggestions else { return [] }
        return projectPrompts(SavedPromptShortcutCacheStore().load())
            .filter { needle.isEmpty || ProjectShortcutCache.folded($0.title).contains(needle) }
            .map(SavedPromptEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SavedPromptEntity] {
        guard ShortcutExposure.showsSuggestions else { return [] }
        return projectPrompts(SavedPromptShortcutCacheStore().load()).map(SavedPromptEntity.init)
    }

    /// Los del proyecto elegido en el atajo (sin proyecto todavía, ninguno).
    private func projectPrompts(_ cache: SavedPromptShortcutCache) -> [CachedPrompt] {
        guard let projectID = intent?.project.id else { return [] }
        return cache.prompts(forProject: projectID)
    }
}
