//
//  SavedPromptShortcutCache.swift
//  ArgosCore
//
//  Títulos de la biblioteca de encargos de cada proyecto, en el dispositivo, para que
//  Atajos y Siri los ofrezcan SIN red. Solo `id` y título: el texto se lee del servidor
//  al ejecutar el atajo (así siempre va el último y nada más se queda en el dispositivo).
//

import Foundation

struct CachedPrompt: Codable, Hashable, Sendable {
    let id: String
    let title: String
}

struct SavedPromptShortcutCache: Codable, Equatable, Sendable {
    /// Tope por proyecto (Atajos no necesita más).
    static let maxPromptsPerProject = 100

    /// Por `CachedProject.id` (servidor + carpeta).
    private(set) var promptsByProject: [String: [CachedPrompt]] = [:]

    static let empty = SavedPromptShortcutCache()

    /// Sustituye lo de un servidor con su biblioteca recién leída.
    func updating(serverID: UUID, projects: [Project], library: PromptLibrary) -> SavedPromptShortcutCache {
        var copy = self
        let prefix = CachedProject.identifier(serverID: serverID, path: "")
        copy.promptsByProject = copy.promptsByProject.filter { !$0.key.hasPrefix(prefix) }
        for project in projects {
            let prompts = library.prompts(forProject: project.id)
                .prefix(Self.maxPromptsPerProject)
                .map { CachedPrompt(id: $0.id, title: $0.displayTitle) }
            let key = CachedProject.identifier(serverID: serverID, path: project.path)
            if !prompts.isEmpty { copy.promptsByProject[key] = Array(prompts) }
        }
        return copy
    }

    /// Olvida los servidores que ya no existen.
    func keepingServers(_ existing: Set<UUID>) -> SavedPromptShortcutCache {
        var copy = self
        copy.promptsByProject = copy.promptsByProject.filter { key, _ in
            CachedProject.parse(identifier: key).map { existing.contains($0.serverID) } ?? false
        }
        return copy
    }

    func prompts(forProject id: String) -> [CachedPrompt] {
        promptsByProject[id] ?? []
    }

    /// Un prompt por su `id` (de cualquier proyecto: los comunes se repiten).
    func prompt(withID id: String) -> CachedPrompt? {
        for key in promptsByProject.keys.sorted() {
            if let prompt = promptsByProject[key]?.first(where: { $0.id == id }) { return prompt }
        }
        return nil
    }
}

struct SavedPromptShortcutCacheStore: Sendable {
    static let key = "shortcuts.promptCache"

    private let defaultsName: String?

    init(suiteName: String? = nil) {
        self.defaultsName = suiteName
    }

    private var defaults: UserDefaults {
        defaultsName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> SavedPromptShortcutCache {
        guard let data = defaults.data(forKey: Self.key) else { return .empty }
        do {
            return try JSONDecoder().decode(SavedPromptShortcutCache.self, from: data)
        } catch {
            Log.store.notice("Caché de encargos de los atajos ilegible; se empieza de cero: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    func save(_ cache: SavedPromptShortcutCache) {
        do {
            defaults.set(try JSONEncoder().encode(cache), forKey: Self.key)
        } catch {
            Log.store.error("No se pudo guardar la caché de encargos de los atajos: \(error.localizedDescription, privacy: .public)")
        }
    }
}
