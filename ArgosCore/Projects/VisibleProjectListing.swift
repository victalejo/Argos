//
//  VisibleProjectListing.swift
//  Argos
//
//  Lo que se ve en la lista de proyectos de UN servidor tras aplicar la búsqueda por
//  texto, el filtro por estado y los grupos plegados (lógica pura, compartida por Mac e
//  iPhone/iPad). Antes vivía duplicada en las vistas del Mac (`SessionsColumn`,
//  `ServerSessionsSection`).
//
//  Reglas:
//  - Texto: subcadena sin distinguir mayúsculas ni acentos, sobre el nombre de sesión
//    del proyecto («grupo/nombre») y su carpeta; en las sesiones sueltas, su nombre.
//  - Estado: `ProjectStatusFilter`; el estado de cada elemento lo da quien llama (el Mac
//    y el iPhone saben de forma distinta qué terminal está abierto).
//  - Con búsqueda o filtro activos, los grupos se muestran desplegados.
//  - Sin grupos reales ni sesiones sueltas, no hay encabezados (solo añadirían ruido) y
//    por tanto nada se pliega.
//

import Foundation

struct VisibleProjectListing: Sendable {
    /// Nombre del grupo de las sesiones que no pertenecen a ningún proyecto (también es
    /// la clave con la que se guarda su plegado en `CollapsedSessionGroups`).
    static let looseGroupName = "Sesiones sueltas"

    /// Un grupo de proyectos tal como se pinta.
    struct Group: Identifiable, Sendable {
        let name: String
        /// Proyectos que pasan los filtros (todos, aunque el grupo esté plegado).
        let entries: [ProjectEntry]
        let isCollapsed: Bool

        var id: String { name }
        /// Filas que se pintan: ninguna si está plegado.
        var visibleEntries: [ProjectEntry] { isCollapsed ? [] : entries }
        var sessionNames: [String] { entries.map(\.project.sessionName) }
    }

    let groups: [Group]
    /// Sesiones sueltas que pasan los filtros.
    let looseSessions: [TmuxSession]
    let isLooseCollapsed: Bool
    /// Si se pintan los encabezados de grupo (y por tanto se puede plegar).
    let showsGroupHeaders: Bool
    /// Hay búsqueda o filtro de estado activos.
    let isFiltering: Bool
    /// El servidor no tiene ni proyectos ni sesiones (antes de filtrar).
    let isSourceEmpty: Bool

    var visibleLooseSessions: [TmuxSession] { isLooseCollapsed ? [] : looseSessions }

    /// Nada pasa los filtros (pero el servidor sí tiene proyectos o sesiones).
    var hasNoMatches: Bool {
        !isSourceEmpty && groups.allSatisfy(\.entries.isEmpty) && looseSessions.isEmpty
    }

    /// Nombre de sesión del primer elemento visible (en el orden en que se pinta,
    /// saltando lo plegado): lo que abre Intro en la búsqueda.
    var firstVisibleSessionName: String? {
        for group in groups {
            if let entry = group.visibleEntries.first { return entry.project.sessionName }
        }
        return visibleLooseSessions.first?.name
    }

    // MARK: - Construcción

    /// - Parameters:
    ///   - entries/looseSessions: lo de `ProjectListing.build` (o `projectListing`).
    ///   - query: texto de búsqueda (vacío = sin filtro).
    ///   - statusFilter: filtro por estado.
    ///   - status: estado de un proyecto; `sessionStatus`, el de una sesión suelta.
    ///   - isCollapsed: si el grupo con ese nombre está plegado (p. ej.
    ///     `CollapsedSessionGroups.isCollapsed(serverID:group:)`).
    init(
        entries: [ProjectEntry],
        looseSessions: [TmuxSession],
        query: String = "",
        statusFilter: ProjectStatusFilter = .all,
        status: (ProjectEntry) -> ProjectStatus,
        sessionStatus: (TmuxSession) -> ProjectStatus,
        isCollapsed: (String) -> Bool = { _ in false }
    ) {
        let matchingEntries = entries.filter {
            Self.matches($0, query: query) && statusFilter.includes(status($0))
        }
        let matchingLoose = looseSessions.filter {
            Self.matches($0, query: query) && statusFilter.includes(sessionStatus($0))
        }
        let filtering = !Self.normalized(query).isEmpty || statusFilter != .all
        let projectGroups = ProjectListing.groups(matchingEntries)
        let headers = projectGroups.count > 1 || !matchingLoose.isEmpty
            || (projectGroups.first.map { $0.name != SessionGrouping.ungroupedName } ?? false)
        let foldable = headers && !filtering

        self.groups = projectGroups.map {
            Group(name: $0.name, entries: $0.entries, isCollapsed: foldable && isCollapsed($0.name))
        }
        self.looseSessions = matchingLoose
        // Las sueltas siempre llevan encabezado cuando las hay.
        self.isLooseCollapsed = !filtering && !matchingLoose.isEmpty && isCollapsed(Self.looseGroupName)
        self.showsGroupHeaders = headers
        self.isFiltering = filtering
        self.isSourceEmpty = entries.isEmpty && looseSessions.isEmpty
    }

    // MARK: - Búsqueda

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Proyecto por nombre de sesión («grupo/nombre») o carpeta.
    static func matches(_ entry: ProjectEntry, query: String) -> Bool {
        let query = normalized(query)
        guard !query.isEmpty else { return true }
        return [entry.project.sessionName, entry.project.path].contains { contains($0, query) }
    }

    static func matches(_ session: TmuxSession, query: String) -> Bool {
        let query = normalized(query)
        return query.isEmpty || contains(session.name, query)
    }

    private static func contains(_ value: String, _ query: String) -> Bool {
        value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Recuentos

    /// Cuántos proyectos y sesiones sueltas caen en cada opción del filtro (sin
    /// búsqueda). El Mac suma los de varios servidores con `merging(_:)`.
    static func statusCounts(
        entries: [ProjectEntry],
        looseSessions: [TmuxSession],
        status: (ProjectEntry) -> ProjectStatus,
        sessionStatus: (TmuxSession) -> ProjectStatus
    ) -> [ProjectStatusFilter: Int] {
        let statuses = entries.map(status) + looseSessions.map(sessionStatus)
        return Dictionary(uniqueKeysWithValues: ProjectStatusFilter.allCases.map { option in
            (option, statuses.filter(option.includes).count)
        })
    }

    /// Suma recuentos de varios servidores.
    static func merging(_ counts: [[ProjectStatusFilter: Int]]) -> [ProjectStatusFilter: Int] {
        counts.reduce(into: [:]) { total, next in total.merge(next, uniquingKeysWith: +) }
    }
}
