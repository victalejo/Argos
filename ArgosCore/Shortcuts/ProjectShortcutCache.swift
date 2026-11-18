//
//  ProjectShortcutCache.swift
//  ArgosCore
//
//  Últimos proyectos conocidos de cada servidor, guardados en el dispositivo para que
//  Atajos, Siri, Spotlight y las acciones rápidas del icono los listen SIN red (los
//  proyectos viven en el `projects.json` del servidor). Solo nombre, grupo, carpeta y
//  sesión: nada de secretos. Se actualiza cada vez que la app carga la lista de un
//  servidor y se olvida lo de los servidores borrados.
//

import Foundation

/// Un proyecto tal como lo recuerda el dispositivo.
struct CachedProject: Codable, Hashable, Sendable, Identifiable {
    let serverID: UUID
    let name: String
    let group: String?
    /// Carpeta ABSOLUTA en el servidor.
    let path: String
    /// Sesión tmux del proyecto (`grupo/nombre`).
    let sessionName: String

    /// Identificador estable para Atajos: servidor + carpeta (el nombre se puede editar).
    var id: String { Self.identifier(serverID: serverID, path: path) }

    /// «grupo/nombre» o solo el nombre.
    var displayName: String { sessionName }

    static func identifier(serverID: UUID, path: String) -> String {
        "\(serverID.uuidString)|\(path)"
    }

    /// Servidor y carpeta de un identificador (`nil` si no tiene esa forma).
    static func parse(identifier: String) -> (serverID: UUID, path: String)? {
        guard let separator = identifier.firstIndex(of: "|"),
              let serverID = UUID(uuidString: String(identifier[..<separator])) else { return nil }
        let path = String(identifier[identifier.index(after: separator)...])
        guard path.hasPrefix("/") else { return nil }
        return (serverID, path)
    }

    init(serverID: UUID, project: Project) {
        self.serverID = serverID
        self.name = project.name
        self.group = project.group
        self.path = project.path
        self.sessionName = project.sessionName
    }

    init(serverID: UUID, name: String, group: String?, path: String, sessionName: String) {
        self.serverID = serverID
        self.name = name
        self.group = group
        self.path = path
        self.sessionName = sessionName
    }
}

/// La caché completa (valor inmutable: cada cambio devuelve una copia).
struct ProjectShortcutCache: Codable, Equatable, Sendable {
    /// Tope por servidor (una lista enorme no debe inflar `UserDefaults`).
    static let maxProjectsPerServer = 200
    /// Cuántos «recientes» se recuerdan.
    static let maxRecents = 10

    /// Proyectos por servidor (clave: UUID en texto), en el orden de la app.
    private(set) var projectsByServer: [String: [CachedProject]] = [:]
    /// Identificadores abiertos hace poco, el último primero.
    private(set) var recentIDs: [String] = []

    static let empty = ProjectShortcutCache()

    /// Sustituye los proyectos de un servidor por los recién cargados.
    func updating(serverID: UUID, projects: [Project]) -> ProjectShortcutCache {
        var copy = self
        let cached = projects.prefix(Self.maxProjectsPerServer).map { CachedProject(serverID: serverID, project: $0) }
        copy.projectsByServer[serverID.uuidString] = Array(cached)
        let known = Set(copy.allProjects.map(\.id))
        copy.recentIDs = copy.recentIDs.filter { known.contains($0) }
        return copy
    }

    /// Olvida los servidores que ya no existen.
    func keepingServers(_ existing: Set<UUID>) -> ProjectShortcutCache {
        var copy = self
        let keys = Set(existing.map(\.uuidString))
        copy.projectsByServer = copy.projectsByServer.filter { keys.contains($0.key) }
        let known = Set(copy.allProjects.map(\.id))
        copy.recentIDs = copy.recentIDs.filter { known.contains($0) }
        return copy
    }

    /// Apunta que se abrió (o se usó en un atajo) un proyecto.
    func markingUsed(_ id: String) -> ProjectShortcutCache {
        guard project(withID: id) != nil else { return self }
        var copy = self
        copy.recentIDs.removeAll { $0 == id }
        copy.recentIDs.insert(id, at: 0)
        copy.recentIDs = Array(copy.recentIDs.prefix(Self.maxRecents))
        return copy
    }

    /// Todos, ordenados por servidor (estable) y dentro en el orden de la app.
    var allProjects: [CachedProject] {
        projectsByServer.keys.sorted().flatMap { projectsByServer[$0] ?? [] }
    }

    func projects(of serverID: UUID) -> [CachedProject] {
        projectsByServer[serverID.uuidString] ?? []
    }

    func project(withID id: String) -> CachedProject? {
        guard let parsed = CachedProject.parse(identifier: id) else { return nil }
        return projects(of: parsed.serverID).first { $0.path == parsed.path }
    }

    /// Los recientes primero y, detrás, el resto (para sugerir en Atajos).
    func suggested(limit: Int = 50) -> [CachedProject] {
        let recents = recentIDs.compactMap(project(withID:))
        let recentSet = Set(recents.map(\.id))
        return Array((recents + allProjects.filter { !recentSet.contains($0.id) }).prefix(limit))
    }

    /// Solo los recientes (acciones rápidas del icono).
    func recents(limit: Int) -> [CachedProject] {
        Array(recentIDs.compactMap(project(withID:)).prefix(limit))
    }

    /// Búsqueda por nombre (sin distinguir mayúsculas ni tildes): primero los que empiezan
    /// por el texto, luego los que lo contienen.
    func matching(_ query: String) -> [CachedProject] {
        let needle = Self.folded(query)
        guard !needle.isEmpty else { return suggested() }
        let candidates = suggested(limit: Int.max)
        let prefix = candidates.filter { Self.folded($0.name).hasPrefix(needle) || Self.folded($0.displayName).hasPrefix(needle) }
        let prefixIDs = Set(prefix.map(\.id))
        let contains = candidates.filter {
            !prefixIDs.contains($0.id) && Self.folded($0.displayName).contains(needle)
        }
        return prefix + contains
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lectura y escritura de la caché en `UserDefaults` (del dispositivo, sin iCloud).
struct ProjectShortcutCacheStore: Sendable {
    static let key = "shortcuts.projectCache"

    private let defaultsName: String?

    /// `suiteName` `nil`: `UserDefaults.standard` (los tests usan una suite propia).
    init(suiteName: String? = nil) {
        self.defaultsName = suiteName
    }

    private var defaults: UserDefaults {
        defaultsName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> ProjectShortcutCache {
        guard let data = defaults.data(forKey: Self.key) else { return .empty }
        do {
            return try JSONDecoder().decode(ProjectShortcutCache.self, from: data)
        } catch {
            Log.store.notice("Caché de proyectos de los atajos ilegible; se empieza de cero: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    func save(_ cache: ProjectShortcutCache) {
        do {
            defaults.set(try JSONEncoder().encode(cache), forKey: Self.key)
        } catch {
            Log.store.error("No se pudo guardar la caché de proyectos de los atajos: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Lee, transforma y guarda; devuelve el resultado.
    @discardableResult
    func update(_ transform: (ProjectShortcutCache) -> ProjectShortcutCache) -> ProjectShortcutCache {
        let updated = transform(load())
        save(updated)
        return updated
    }
}
