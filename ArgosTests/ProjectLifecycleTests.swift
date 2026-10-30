//
//  ProjectLifecycleTests.swift
//  ArgosTests
//
//  Ciclo de vida de proyectos en el ViewModel (con `MockSSHService`): abrir crea la
//  sesión en la carpeta con el comando de arranque, detener la mata conservando el
//  proyecto, importar y editar.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Ciclo de vida de proyectos")
struct ProjectLifecycleTests {

    private func session(_ name: String) -> TmuxSession {
        TmuxSession(name: name, windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func loadedVM(_ mock: MockSSHService) async -> SessionsViewModel {
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        return vm
    }

    @Test("Abrir un proyecto detenido crea su sesión con el comando predeterminado")
    func openStopped() async throws {
        let mock = MockSSHService()
        let coro = Project(name: "coro", group: "ia", path: "/srv/coro")
        mock.storedProjects = [coro]
        let vm = await loadedVM(mock)
        #expect(vm.projectListing.entries.first?.isRunning == false)

        try await vm.openProject(coro, defaultStartupCommand: "cc --continue")

        #expect(mock.startedProjects.count == 1)
        #expect(mock.startedProjects.first?.session == "ia/coro")
        #expect(mock.startedProjects.first?.path == "/srv/coro")
        #expect(mock.startedProjects.first?.command == "cc --continue")
        #expect(vm.projectListing.entries.first?.isRunning == true)
    }

    @Test("Abrir un proyecto que ya corre no crea otra sesión")
    func openRunning() async throws {
        let mock = MockSSHService()
        let coro = Project(name: "coro", path: "/srv/coro")
        mock.storedProjects = [coro]
        mock.sessions = [session("coro")]
        let vm = await loadedVM(mock)

        try await vm.openProject(coro, defaultStartupCommand: "cc")
        #expect(mock.startedProjects.isEmpty)
    }

    @Test("Comando vacío del proyecto no lanza nada")
    func openWithoutCommand() async throws {
        let mock = MockSSHService()
        let web = Project(name: "web", path: "/w", startupCommand: "")
        mock.storedProjects = [web]
        let vm = await loadedVM(mock)
        try await vm.openProject(web, defaultStartupCommand: "cc --continue")
        #expect(mock.startedProjects.first.map { $0.command == nil } == true)
    }

    @Test("Carpeta inexistente: error claro y no se crea sesión")
    func openMissingFolder() async {
        let mock = MockSSHService()
        let gone = Project(name: "gone", path: "/borrada")
        mock.storedProjects = [gone]
        mock.missingFolders = ["/borrada"]
        let vm = await loadedVM(mock)
        await #expect(throws: ProjectError.missingFolder("/borrada")) {
            try await vm.openProject(gone, defaultStartupCommand: "cc")
        }
        #expect(vm.sessions.isEmpty)
    }

    @Test("Detener mata la sesión pero conserva el proyecto")
    func stopKeepsProject() async throws {
        let mock = MockSSHService()
        let coro = Project(name: "coro", path: "/srv/coro")
        mock.storedProjects = [coro]
        mock.sessions = [session("coro")]
        let vm = await loadedVM(mock)

        try await vm.stopProject(coro)

        #expect(mock.stoppedSessions == ["coro"])
        #expect(vm.projects.map(\.name) == ["coro"])
        #expect(vm.projectListing.entries.first?.isRunning == false)
    }

    @Test("Importar convierte sesiones sueltas en proyectos con su carpeta")
    func importLoose() async throws {
        let mock = MockSSHService()
        mock.sessions = [session("ia portafolio/coro"), session("roomies")]
        mock.panePaths = ["ia portafolio/coro": "/home/v/coro", "roomies": "/home/v/roomies"]
        let vm = await loadedVM(mock)
        #expect(vm.projectListing.looseSessions.count == 2)

        let candidates = try await vm.importCandidates()
        try await vm.importProjects(candidates)

        #expect(vm.projectListing.looseSessions.isEmpty)
        #expect(Set(mock.storedProjects.map(\.sessionName)) == ["ia portafolio/coro", "roomies"])
        #expect(vm.projectListing.entries.allSatisfy(\.isRunning))
    }

    @Test("Renombrar un proyecto en marcha renombra también su sesión tmux")
    func renameRunning() async throws {
        let mock = MockSSHService()
        let coro = Project(name: "coro", path: "/srv/coro")
        mock.storedProjects = [coro]
        mock.sessions = [session("coro")]
        let vm = await loadedVM(mock)

        var renamed = coro
        renamed.name = "coro-v2"
        try await vm.saveProject(renamed)

        #expect(mock.renamedTo == ["coro-v2"])
        #expect(mock.storedProjects.map(\.name) == ["coro-v2"])
    }

    @Test("Quitar un proyecto no mata su sesión: pasa a sesión suelta")
    func removeKeepsSession() async throws {
        let mock = MockSSHService()
        let coro = Project(name: "coro", path: "/srv/coro")
        mock.storedProjects = [coro]
        mock.sessions = [session("coro")]
        let vm = await loadedVM(mock)

        try await vm.removeProject(coro)

        #expect(mock.stoppedSessions.isEmpty)
        #expect(vm.projectListing.looseSessions.map(\.name) == ["coro"])
    }

    @Test("Convertir una sesión suelta en proyecto la adopta (no es duplicado)")
    func convertLooseSession() async throws {
        let mock = MockSSHService()
        mock.sessions = [session("roomies")]
        let vm = await loadedVM(mock)

        await #expect(throws: ProjectError.duplicateName("roomies")) {
            try await vm.saveProject(Project(name: "roomies", path: "/r"))
        }
        try await vm.saveProject(Project(name: "roomies", path: "/r"), adoptingSession: "roomies")
        #expect(vm.projectListing.entries.first?.isRunning == true)
        #expect(vm.projectListing.looseSessions.isEmpty)
    }
}
