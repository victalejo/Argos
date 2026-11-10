//
//  GitSummaryTests.swift
//  ArgosTests
//
//  Resumen git de los proyectos (insignia de la lista y aviso «Claude terminó»):
//  parser de la salida, comando remoto, texto del aviso y espaciado de lecturas.
//

import Foundation
import Testing
@testable import Argos

@Suite("GitSummaryParser")
struct GitSummaryParserTests {

    private let paths = ["/srv/app", "/srv/con espacio", "/srv/nada"]

    @Test("Parsea rama, ahead/behind y archivos por índice de ruta; ignora no-repos y ruido")
    func parses() {
        let output = """
        bienvenido al servidor
        ARGOS_GSUM 0 5 ## main...origin/main [ahead 2, behind 1]
        ARGOS_GSUM 1 0 ## No commits yet on main
        ARGOS_GSUM 2 -
        """
        let result = GitSummaryParser.parse(output, paths: paths)
        #expect(result.count == 2)
        let app = result["/srv/app"]
        #expect(app?.changedCount == 5)
        #expect(app?.branch.name == "main")
        #expect(app?.branch.ahead == 2)
        #expect(app?.branch.behind == 1)
        #expect(result["/srv/con espacio"]?.branch.hasCommits == false)
        #expect(result["/srv/nada"] == nil)
    }

    @Test("Índices fuera de rango o líneas mal formadas no rompen nada")
    func malformed() {
        let output = "ARGOS_GSUM 9 1 ## main\nARGOS_GSUM x 1 ## main\nARGOS_GSUM 0 1 sin-cabecera\n"
        #expect(GitSummaryParser.parse(output, paths: paths).isEmpty)
    }

    @Test("El comando entrecomilla cada ruta y no toma el lock del índice")
    func command() {
        let command = GitSummaryCommands.summaries(paths: ["/srv/a b", "/srv/x'y"])
        #expect(command.hasPrefix("sh -c "))
        #expect(command.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(command.contains("a b"))
        #expect(!command.contains("for p in /srv/a b"))
    }

    @Test("Solo es «destacable» si hay cambios o commits por subir/traer")
    func noteworthy() {
        let clean = GitRepoSummary(branch: .unknown, changedCount: 0)
        #expect(!clean.isNoteworthy)
        #expect(clean.label.contains("sin cambios"))
        let dirty = GitRepoSummary(branch: .unknown, changedCount: 1)
        #expect(dirty.isNoteworthy)
        #expect(dirty.label.contains("1 archivo cambiado"))
    }
}

@Suite("ClaudeDoneMessage")
struct ClaudeDoneMessageTests {

    @Test("Sin datos o sin cambios: el texto de siempre")
    func plain() {
        #expect(ClaudeDoneMessage.body(changedFiles: nil) == "Terminó de responder.")
        #expect(ClaudeDoneMessage.body(changedFiles: 0) == "Terminó de responder.")
    }

    @Test("Con cambios: cuántos archivos (singular y plural)")
    func withChanges() {
        #expect(ClaudeDoneMessage.body(changedFiles: 1).contains("1 archivo cambiado"))
        #expect(ClaudeDoneMessage.body(changedFiles: 5).contains("5 archivos cambiados"))
    }
}

@MainActor
@Suite("SessionsViewModel: resumen git")
struct SessionsViewModelGitTests {

    private let project = Project(name: "app", path: "/srv/app")

    private func loadedViewModel() async -> (SessionsViewModel, MockSSHService) {
        let mock = MockSSHService()
        mock.storedProjects = [project, Project(name: "app2", path: "/srv/app")]
        mock.gitSummariesResult = ["/srv/app": GitRepoSummary(branch: .unknown, changedCount: 3)]
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        return (vm, mock)
    }

    @Test("Una sola consulta para todos los proyectos, sin rutas repetidas")
    func singleRequest() async {
        let (vm, mock) = await loadedViewModel()
        await vm.refreshGitSummaries()
        #expect(mock.gitSummaryRequests == [["/srv/app"]])
        #expect(vm.gitSummary(for: project)?.changedCount == 3)
        #expect(vm.gitSummary(forSession: "app")?.changedCount == 3)
        #expect(vm.gitSummary(forSession: "suelta") == nil)
    }

    @Test("Espacia las lecturas salvo que se fuerce (Claude terminó)")
    func throttles() async {
        let (vm, mock) = await loadedViewModel()
        let start = Date()
        await vm.refreshGitSummaries(now: start)
        await vm.refreshGitSummaries(now: start.addingTimeInterval(5))
        #expect(mock.gitSummaryRequests.count == 1)
        await vm.refreshGitSummaries(force: true, now: start.addingTimeInterval(6))
        #expect(mock.gitSummaryRequests.count == 2)
        await vm.refreshGitSummaries(now: start.addingTimeInterval(6 + SessionsViewModel.gitSummaryInterval))
        #expect(mock.gitSummaryRequests.count == 3)
    }

    @Test("Un fallo conserva el último resumen")
    func keepsLastOnFailure() async {
        let (vm, mock) = await loadedViewModel()
        await vm.refreshGitSummaries()
        mock.gitError = GitCommandError(message: "red caída")
        await vm.refreshGitSummaries(force: true)
        #expect(vm.gitSummary(for: project)?.changedCount == 3)
    }
}
