//
//  VisibleProjectListingTests.swift
//  ArgosTests
//
//  Búsqueda, filtro por estado, grupos plegados y recuentos de la lista de proyectos
//  (compartido Mac / iPhone).
//

import Foundation
import Testing
@testable import Argos

@Suite("Lista visible de proyectos")
struct VisibleProjectListingTests {

    private static func session(_ name: String, attached: Bool = false) -> TmuxSession {
        TmuxSession(name: name, windowCount: 1, isAttached: attached, createdAt: Date(timeIntervalSince1970: 0))
    }

    private static func entry(_ name: String, group: String? = nil, path: String? = nil, running: Bool = false) -> ProjectEntry {
        let project = Project(name: name, group: group, path: path ?? "/srv/\(name)")
        return ProjectEntry(project: project, session: running ? session(project.sessionName) : nil)
    }

    /// Estado simple: detenido sin sesión, dormido con ella.
    private static func status(_ entry: ProjectEntry) -> ProjectStatus {
        entry.isRunning ? .dormant : .stopped
    }

    private static func listing(
        _ entries: [ProjectEntry],
        loose: [TmuxSession] = [],
        query: String = "",
        filter: ProjectStatusFilter = .all,
        collapsed: Set<String> = []
    ) -> VisibleProjectListing {
        VisibleProjectListing(
            entries: entries, looseSessions: loose, query: query, statusFilter: filter,
            status: status, sessionStatus: { _ in .background },
            isCollapsed: { collapsed.contains($0) }
        )
    }

    @Test("Busca por nombre de sesión y carpeta, sin mayúsculas ni acentos")
    func textSearch() {
        let entries = [
            Self.entry("api", group: "trabajo"),
            Self.entry("web", path: "/home/yo/Diseño"),
            Self.entry("notas"),
        ]
        let byGroup = Self.listing(entries, query: "TRABAJO")
        #expect(byGroup.groups.flatMap { $0.entries }.map { $0.project.name } == ["api"])
        let byFolder = Self.listing(entries, query: " diseno ")
        #expect(byFolder.groups.flatMap { $0.entries }.map { $0.project.name } == ["web"])
        #expect(byFolder.isFiltering)
        let loose = Self.listing(entries, loose: [Self.session("Pruebas"), Self.session("otra")], query: "prué")
        #expect(loose.looseSessions.map { $0.name } == ["Pruebas"])
        #expect(Self.listing(entries, query: "   ").isFiltering == false)
    }

    @Test("Filtra por estado proyectos y sesiones sueltas")
    func statusFilter() {
        let entries = [Self.entry("a", running: true), Self.entry("b")]
        let loose = [Self.session("suelta")]
        let stopped = Self.listing(entries, loose: loose, filter: .stopped)
        #expect(stopped.groups.flatMap { $0.entries }.map { $0.project.name } == ["b"])
        #expect(stopped.looseSessions.isEmpty)
        let background = Self.listing(entries, loose: loose, filter: .background)
        #expect(background.groups.flatMap { $0.entries }.isEmpty)
        #expect(background.looseSessions.map { $0.name } == ["suelta"])
        let none = Self.listing(entries, filter: .onMac)
        #expect(none.hasNoMatches)
        #expect(!none.isSourceEmpty)
    }

    @Test("Los grupos plegados no pintan filas, salvo con búsqueda o filtro")
    func collapsedGroups() {
        let entries = [Self.entry("api", group: "trabajo"), Self.entry("notas")]
        let loose = [Self.session("suelta")]
        let collapsed: Set<String> = ["trabajo", VisibleProjectListing.looseGroupName]
        let plain = Self.listing(entries, loose: loose, collapsed: collapsed)
        #expect(plain.showsGroupHeaders)
        let trabajo = plain.groups.first { $0.name == "trabajo" }
        #expect(trabajo?.isCollapsed == true)
        #expect(trabajo?.visibleEntries.isEmpty == true)
        #expect(trabajo?.entries.count == 1)   // el recuento sigue contando lo plegado
        #expect(plain.isLooseCollapsed)
        #expect(plain.visibleLooseSessions.isEmpty)
        #expect(plain.firstVisibleSessionName == "notas")   // salta lo plegado

        let searching = Self.listing(entries, loose: loose, query: "a", collapsed: collapsed)
        #expect(searching.groups.allSatisfy { !$0.isCollapsed })
        #expect(!searching.isLooseCollapsed)
    }

    @Test("Sin grupos reales ni sueltas no hay encabezados y nada se pliega")
    func noHeaders() {
        let entries = [Self.entry("a"), Self.entry("b")]
        let result = Self.listing(entries, collapsed: [SessionGrouping.ungroupedName])
        #expect(!result.showsGroupHeaders)
        #expect(result.groups.count == 1)
        #expect(result.groups[0].isCollapsed == false)
        #expect(result.firstVisibleSessionName == "a")
        // Un único grupo con nombre sí lleva encabezado.
        #expect(Self.listing([Self.entry("a", group: "g")]).showsGroupHeaders)
    }

    @Test("Servidor vacío y orden de grupos")
    func emptyAndOrder() {
        let empty = Self.listing([])
        #expect(empty.isSourceEmpty)
        #expect(!empty.hasNoMatches)
        #expect(empty.firstVisibleSessionName == nil)
        let ordered = Self.listing([Self.entry("x"), Self.entry("y", group: "zeta"), Self.entry("z", group: "alfa")])
        #expect(ordered.groups.map { $0.name } == ["alfa", "zeta", SessionGrouping.ungroupedName])
        #expect(ordered.groups.first?.sessionNames == ["alfa/z"])
    }

    @Test("Recuentos por estado y suma entre servidores")
    func counts() {
        let entries = [Self.entry("a", running: true), Self.entry("b"), Self.entry("c")]
        let counts = VisibleProjectListing.statusCounts(
            entries: entries, looseSessions: [Self.session("s")],
            status: Self.status, sessionStatus: { _ in .background }
        )
        #expect(counts[.all] == 4)
        #expect(counts[.stopped] == 2)
        #expect(counts[.dormant] == 1)
        #expect(counts[.background] == 1)
        #expect(counts[.open] == 0)
        let merged = VisibleProjectListing.merging([counts, counts])
        #expect(merged[.all] == 8)
        #expect(merged[.open] == 0)
    }
}
