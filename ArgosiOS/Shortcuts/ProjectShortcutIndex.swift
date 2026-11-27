//
//  ProjectShortcutIndex.swift
//  ArgosiOS
//
//  Mantiene al día lo que el sistema sabe de los proyectos: la caché del dispositivo
//  (`ProjectShortcutCache`, la leen Atajos y Siri), las frases con proyecto de
//  `ArgosShortcuts` y el índice de Spotlight. Tocar un resultado de Spotlight abre el
//  proyecto por el mismo camino que un aviso (ver `RootView`).
//

import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import Foundation

@MainActor
enum ProjectShortcutIndex {
    private static let store = ProjectShortcutCacheStore()
    /// Dominio de Spotlight de los proyectos (se borra entero al reindexar).
    static let spotlightDomain = "com.iaportafolio.argos.projects"

    private static let promptStore = SavedPromptShortcutCacheStore()

    /// La app cargó la lista de proyectos de un servidor (con su biblioteca de encargos).
    static func update(serverID: UUID, projects: [Project], prompts: PromptLibrary) {
        let existing = Set(ServerStore().servers.map(\.id))
        let promptsBefore = promptStore.load()
        let promptsAfter = promptsBefore.updating(serverID: serverID, projects: projects, library: prompts).keepingServers(existing)
        if promptsAfter != promptsBefore { promptStore.save(promptsAfter) }
        let before = store.load()
        let after = before.updating(serverID: serverID, projects: projects).keepingServers(existing)
        guard after != before else { return }
        store.save(after)
        publish(after)
    }

    /// Se abrió un proyecto (en la app o desde un atajo): sube en las sugerencias.
    static func markUsed(_ id: String) {
        let before = store.load()
        let after = before.markingUsed(id)
        guard after != before else { return }
        store.save(after)
    }

    /// Ruta para un resultado de Spotlight (`nil` si el proyecto ya no está).
    static func route(forSpotlightIdentifier id: String) -> NotificationRoute? {
        NotificationRoute.open(identifier: id, cache: store.load())
    }

    private static func publish(_ cache: ProjectShortcutCache) {
        ArgosShortcuts.updateAppShortcutParameters()
        reindexSpotlight(cache)
    }

    /// Cambió el bloqueo de la app o «Mostrar proyectos en Spotlight y Siri»: se publica
    /// o se retira lo que el sistema muestra fuera de la app.
    static func refreshExposure() {
        publish(store.load())
    }

    /// Reindexa todo el dominio (son pocos proyectos): así desaparece lo borrado.
    /// Con el bloqueo activo (y sin permiso para mostrarlos) solo se borra: los nombres de
    /// proyectos no aparecen en Spotlight.
    private static func reindexSpotlight(_ cache: ProjectShortcutCache) {
        let names = Dictionary(ServerStore().servers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let visible = ShortcutExposure.showsSuggestions ? cache.allProjects : []
        let projects = visible.compactMap { project in names[project.serverID].map { (project, $0) } }
        Task { @MainActor in
            let items = projects.map { project, serverName in
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = project.displayName
                attributes.contentDescription = String(localized: "Proyecto de Argos en \(serverName)")
                attributes.keywords = ["Argos", project.name, serverName]
                return CSSearchableItem(uniqueIdentifier: project.id, domainIdentifier: spotlightDomain, attributeSet: attributes)
            }
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: [spotlightDomain])
                if !items.isEmpty { try await index.indexSearchableItems(items) }
            } catch {
                Log.store.notice("Spotlight: no se pudieron indexar los proyectos: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
