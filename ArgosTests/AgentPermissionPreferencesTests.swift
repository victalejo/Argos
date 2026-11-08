//
//  AgentPermissionPreferencesTests.swift
//  ArgosTests
//
//  Resolución del modo de permisos: proyecto > Ajustes > «todos los permisos».
//

import Testing
import Foundation
@testable import Argos

@Suite("Preferencias de permisos del agente")
struct AgentPermissionPreferencesTests {

    private let defaults: UserDefaults
    private let serverID = UUID()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "argos-tests-\(UUID())"))
    }

    @Test func porDefectoSonTodosLosPermisos() {
        #expect(AgentPermissionPreferences.globalMode(defaults: defaults) == .bypassPermissions)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: serverID, workingDirectory: "/srv/app", defaults: defaults
        ) == .bypassPermissions)
    }

    @Test func elAjusteGlobalCambiaElModoDeTodosLosProyectos() {
        defaults.set("plan", forKey: AgentPermissionPreferences.globalKey)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: serverID, workingDirectory: "/srv/app", defaults: defaults
        ) == .plan)
    }

    @Test func elProyectoTienePrioridadSoloEnEseProyecto() {
        defaults.set("plan", forKey: AgentPermissionPreferences.globalKey)
        let key = AgentPermissionPreferences.projectKey(serverID: serverID, workingDirectory: "/srv/app")
        defaults.set("acceptEdits", forKey: key)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: serverID, workingDirectory: "/srv/app", defaults: defaults
        ) == .acceptEdits)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: serverID, workingDirectory: "/srv/otro", defaults: defaults
        ) == .plan)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: UUID(), workingDirectory: "/srv/app", defaults: defaults
        ) == .plan)
    }

    @Test func usarElAjusteGlobalEsLaEleccionVacia() {
        let key = AgentPermissionPreferences.projectKey(serverID: serverID, workingDirectory: "/srv/app")
        defaults.set(AgentPermissionPreferences.useGlobalChoice, forKey: key)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: serverID, workingDirectory: "/srv/app", defaults: defaults
        ) == .bypassPermissions)
    }

    @Test func unAjusteGlobalDesconocidoPregunta() {
        defaults.set("basura", forKey: AgentPermissionPreferences.globalKey)
        #expect(AgentPermissionPreferences.globalMode(defaults: defaults) == .default)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: serverID, workingDirectory: "/srv/app", defaults: defaults
        ) == .default)
    }

    @Test func unaEleccionDeProyectoDesconocidaPreguntaAunqueAjustesDigaOtraCosa() {
        defaults.set("bypassPermissions", forKey: AgentPermissionPreferences.globalKey)
        let key = AgentPermissionPreferences.projectKey(serverID: serverID, workingDirectory: "/srv/app")
        defaults.set("modo-futuro", forKey: key)
        #expect(AgentPermissionPreferences.effectiveMode(
            serverID: serverID, workingDirectory: "/srv/app", defaults: defaults
        ) == .default)
    }

    @Test func laClaveDelProyectoNoLlevaPuntos() {
        // Las claves con puntos no se observan bien (KVO las toma por rutas), y una ruta
        // de carpeta suele llevarlos.
        let key = AgentPermissionPreferences.projectKey(serverID: serverID, workingDirectory: "/srv/app.v2/x.y")
        #expect(!key.contains("."))
    }

    @Test func cadaModoTieneTextosParaLaInterfaz() {
        for mode in ClaudeAgentCommand.PermissionMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(!mode.detail.isEmpty)
            #expect(!mode.symbolName.isEmpty)
        }
    }
}

@Suite("Sesión del agente del Mac")
struct ClaudeAgentSessionTokenTests {

    @MainActor
    private func firstStdinLine(token: String?, mock: MockSSHService) async throws -> [String] {
        let session = ClaudeAgentSession(
            service: mock, command: "cmd", workingDirectory: "/repo", oauthToken: token
        )
        session.sendUserText("hola")
        for _ in 0..<100 where mock.agentStdinLines.count < (token == nil ? 1 : 2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.stop()
        return mock.agentStdinLines
    }

    @MainActor
    @Test func elTokenEsLaPrimeraLineaDeStdinYNoVaEnElComando() async throws {
        let mock = MockSSHService()
        let lines = try await firstStdinLine(token: "tok-123", mock: mock)
        #expect(lines.first == "tok-123")
        #expect(lines.count == 2)
        #expect(mock.lastAgentCommand == "cmd")
    }
}
