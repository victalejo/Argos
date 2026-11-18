//
//  ShortcutEntities.swift
//  ArgosiOS
//
//  Servidores y proyectos tal como los ve la app Atajos y Siri. Los proyectos salen de la
//  caché del dispositivo (`ProjectShortcutCache`): se listan sin red ni conexión SSH, con
//  los últimos conocidos de cada servidor. Nada de secretos: solo nombres y carpetas.
//
//  Qué se ve con el bloqueo de Argos activo: los atajos ya creados se siguen resolviendo
//  (por identificador) y buscar escribiendo en Atajos encuentra proyectos por nombre,
//  pero las SUGERENCIAS (listas que el sistema muestra solo, frases de Siri con nombre de
//  proyecto) quedan vacías salvo que el usuario active «Mostrar proyectos en Spotlight y
//  Siri» en Ajustes. Nunca se expone más que el nombre del servidor y del proyecto.
//

import AppIntents
import Foundation

// MARK: - Servidor

struct ServerEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Servidor" }
    static var defaultQuery: ServerEntityQuery { ServerEntityQuery() }

    let id: UUID
    let name: String
    let host: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(host)")
    }

    init(_ server: Server) {
        id = server.id
        name = server.name
        host = server.host
    }
}

struct ServerEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        let servers = ServerStore().servers
        return identifiers.compactMap { id in servers.first { $0.id == id }.map(ServerEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ServerEntity] {
        let needle = ProjectShortcutCache.folded(string)
        guard !needle.isEmpty || ShortcutExposure.showsSuggestions else { return [] }
        return ServerStore().servers
            .filter { needle.isEmpty || ProjectShortcutCache.folded($0.name).contains(needle) }
            .map(ServerEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ServerEntity] {
        guard ShortcutExposure.showsSuggestions else { return [] }
        return ServerStore().servers.map(ServerEntity.init)
    }
}

// MARK: - Proyecto

struct ProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Proyecto" }
    static var defaultQuery: ProjectEntityQuery { ProjectEntityQuery() }

    /// `CachedProject.id`: servidor + carpeta.
    let id: String
    let name: String
    let serverName: String
    let path: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(serverName)")
    }

    init(_ project: CachedProject, serverName: String) {
        id = project.id
        name = project.displayName
        self.serverName = serverName
        path = project.path
    }
}

struct ProjectEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        let cache = ProjectShortcutCacheStore().load()
        return entities(identifiers.compactMap(cache.project(withID:)))
    }

    @MainActor
    func entities(matching string: String) async throws -> [ProjectEntity] {
        guard !ProjectShortcutCache.folded(string).isEmpty || ShortcutExposure.showsSuggestions else { return [] }
        return entities(ProjectShortcutCacheStore().load().matching(string))
    }

    @MainActor
    func suggestedEntities() async throws -> [ProjectEntity] {
        guard ShortcutExposure.showsSuggestions else { return [] }
        return entities(ProjectShortcutCacheStore().load().suggested())
    }

    /// Solo los de servidores que siguen en Argos (con su nombre actual).
    @MainActor
    private func entities(_ projects: [CachedProject]) -> [ProjectEntity] {
        let names = Dictionary(ServerStore().servers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return projects.compactMap { project in
            names[project.serverID].map { ProjectEntity(project, serverName: $0) }
        }
    }
}

// MARK: - Exposición con el bloqueo activo

enum ShortcutExposure {
    /// Sugerencias de Atajos/Siri y Spotlight (ver `AppLockPolicy.exposesProjectNames`).
    static var showsSuggestions: Bool {
        let defaults = UserDefaults.standard
        return AppLockPolicy.exposesProjectNames(
            enabled: defaults.bool(forKey: AppLockPolicy.enabledKey),
            exposesWhenLocked: defaults.bool(forKey: AppLockPolicy.exposesProjectsWhenLockedKey)
        )
    }
}

// MARK: - Pestaña

enum ProjectTabOption: String, AppEnum {
    case terminal, files, changes, agent

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Pestaña" }
    static var caseDisplayRepresentations: [ProjectTabOption: DisplayRepresentation] {
        [
            .terminal: "Terminal",
            .files: "Archivos",
            .changes: "Cambios",
            .agent: "Agentes",
        ]
    }

    var routeTab: NotificationRoute.Tab {
        switch self {
        case .terminal: return .terminal
        case .files: return .files
        case .changes: return .changes
        case .agent: return .agent
        }
    }
}
