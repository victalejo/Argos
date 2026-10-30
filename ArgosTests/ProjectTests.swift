//
//  ProjectTests.swift
//  ArgosTests
//
//  Proyectos anclados a carpeta: identidad con la sesión tmux, cruce con sesiones
//  vivas, importación de sesiones existentes, validación y fichero projects.json.
//

import Foundation
import Testing
@testable import Argos

@Suite("Proyectos")
struct ProjectTests {

    private func session(_ name: String) -> TmuxSession {
        TmuxSession(name: name, windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Identidad y comando

    @Test("El nombre de sesión es grupo/nombre, o nombre sin grupo")
    func sessionName() {
        #expect(Project(name: "coro", group: "ia portafolio", path: "/x").sessionName == "ia portafolio/coro")
        #expect(Project(name: "roomies", path: "/x").sessionName == "roomies")
        #expect(Project(name: "roomies", group: "", path: "/x").sessionName == "roomies")
    }

    @Test("Comando de arranque: nil usa el predeterminado, vacío no lanza nada")
    func startupCommand() {
        #expect(Project(name: "a", path: "/x").resolvedStartupCommand(default: "cc --continue") == "cc --continue")
        #expect(Project(name: "a", path: "/x", startupCommand: "npm run dev").resolvedStartupCommand(default: "cc") == "npm run dev")
        #expect(Project(name: "a", path: "/x", startupCommand: "  ").resolvedStartupCommand(default: "cc") == nil)
        #expect(Project(name: "a", path: "/x").resolvedStartupCommand(default: "") == nil)
    }

    // MARK: - Cruce con sesiones

    @Test("Proyectos con sesión corren; sin sesión están detenidos; el resto son sueltas")
    func buildListing() {
        let coro = Project(name: "coro", group: "ia", path: "/c")
        let vetto = Project(name: "vetto", group: "ia", path: "/v")
        let (entries, loose) = ProjectListing.build(
            projects: [vetto, coro],
            sessions: [session("ia/coro"), session("suelta"), session("ia/vetto-2")]
        )
        #expect(entries.map(\.project.name) == ["coro", "vetto"])
        #expect(entries[0].isRunning)
        #expect(!entries[1].isRunning)
        #expect(loose.map(\.name) == ["ia/vetto-2", "suelta"])
    }

    @Test("Grupos ordenados con 'General' al final")
    func groups() {
        let entries = [
            ProjectEntry(project: Project(name: "a", path: "/a"), session: nil),
            ProjectEntry(project: Project(name: "b", group: "tmh", path: "/b"), session: nil),
            ProjectEntry(project: Project(name: "c", group: "ia", path: "/c"), session: nil),
        ]
        #expect(ProjectListing.groups(entries).map(\.name) == ["ia", "tmh", SessionGrouping.ungroupedName])
    }

    // MARK: - Importación

    @Test("Importar conserva el nombre de sesión exacto (grupo/nombre)")
    func importKeepsSessionName() throws {
        let grouped = try #require(ProjectListing.importCandidate(session: session("ia portafolio/coro"), path: "/home/v/coro"))
        #expect(grouped.group == "ia portafolio")
        #expect(grouped.name == "coro")
        #expect(grouped.sessionName == "ia portafolio/coro")
        #expect(grouped.startupCommand == nil)

        let plain = try #require(ProjectListing.importCandidate(session: session("roomies"), path: "/r"))
        #expect(plain.group == nil)
        #expect(plain.sessionName == "roomies")

        let odd = try #require(ProjectListing.importCandidate(session: session("foo/"), path: "/f"))
        #expect(odd.sessionName == "foo/")
    }

    @Test("Sin ruta absoluta no hay candidato")
    func importNeedsPath() {
        #expect(ProjectListing.importCandidate(session: session("x"), path: nil) == nil)
        #expect(ProjectListing.importCandidate(session: session("x"), path: "relativa") == nil)
    }

    @Test("Ruta del primer panel de cada sesión (menor ventana y panel)")
    func firstPanePaths() {
        let output = """
        2|1|/b|ia/coro
        1|2|/c|ia/coro
        1|1|/a|ia/coro
        1|1|/r|real bros|x
        """
        let paths = ProjectListing.firstPanePaths(listPanesOutput: output)
        #expect(paths["ia/coro"] == "/a")
        #expect(paths["real bros|x"] == "/r")
    }

    // MARK: - Validación

    @Test("Valida nombre, grupo, ruta absoluta y unicidad")
    func validation() throws {
        let existing = Project(name: "coro", group: "ia", path: "/c")
        let ok = try ProjectListing.validate(
            Project(name: "  vetto ", group: " ia ", path: " /v "),
            among: [existing], looseSessions: []
        )
        #expect(ok.name == "vetto")
        #expect(ok.group == "ia")
        #expect(ok.path == "/v")

        #expect(throws: ProjectError.duplicateName("ia/coro")) {
            try ProjectListing.validate(Project(name: "coro", group: "ia", path: "/x"), among: [existing], looseSessions: [])
        }
        #expect(throws: ProjectError.duplicateName("suelta")) {
            try ProjectListing.validate(Project(name: "suelta", path: "/x"), among: [], looseSessions: [session("suelta")])
        }
        #expect(throws: ProjectError.invalidPath) {
            try ProjectListing.validate(Project(name: "x", path: "~/x"), among: [], looseSessions: [])
        }
        #expect(throws: (any Error).self) {
            try ProjectListing.validate(Project(name: "a/b", path: "/x"), among: [], looseSessions: [])
        }
        #expect(throws: (any Error).self) {
            try ProjectListing.validate(Project(name: "a", group: "x/y", path: "/x"), among: [], looseSessions: [])
        }
    }

    @Test("Editar un proyecto no choca consigo mismo")
    func validationAllowsSelf() throws {
        let existing = Project(name: "coro", group: "ia", path: "/c")
        var edited = existing
        edited.path = "/nueva"
        #expect(try ProjectListing.validate(edited, among: [existing], looseSessions: []).path == "/nueva")
    }

    // MARK: - projects.json

    @Test("projects.json: ida y vuelta, vacío e inválido")
    func projectsFile() throws {
        let file = ProjectsFile(projects: [Project(name: "coro", group: "ia", path: "/c", startupCommand: "")])
        let decoded = try ProjectsFile.decode(String(decoding: try file.encoded(), as: UTF8.self))
        #expect(decoded.projects.map(\.sessionName) == ["ia/coro"])
        #expect(decoded.projects[0].startupCommand == "")
        #expect(try ProjectsFile.decode("") == .empty)
        #expect(throws: ProjectError.invalidFile) { try ProjectsFile.decode("{ roto") }
    }

    @Test("Ajuste global: predeterminado de fábrica y persistencia")
    @MainActor
    func settingsPersist() {
        let suite = "argos.tests.projects.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        #expect(ProjectSettings(defaults: defaults).defaultStartupCommand == "cc --continue")
        ProjectSettings(defaults: defaults).defaultStartupCommand = "cc"
        #expect(ProjectSettings(defaults: defaults).defaultStartupCommand == "cc")
        defaults.removePersistentDomain(forName: suite)
    }
}
