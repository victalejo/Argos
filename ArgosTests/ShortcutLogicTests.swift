//
//  ShortcutLogicTests.swift
//  ArgosTests
//
//  Lógica pura de los atajos de iOS: a qué agente se manda el encargo, cuándo se pide
//  confirmación y cuándo se niega por memoria; caché de proyectos del dispositivo; rutas
//  hacia un proyecto o el chat de un agente; y mensajes de conexión perdida.
//

import Foundation
import Testing
@testable import Argos

@Suite("Atajos: qué agente recibe el encargo")
struct ShortcutAgentPlannerTests {
    private let folder = "/srv/app"

    private func agent(
        _ id: String = UUID().uuidString.lowercased(),
        folder: String = "/srv/app",
        alive: Bool,
        hibernated: Bool = false,
        mode: String? = ClaudeAgentCommand.PermissionMode.bypassPermissions.rawValue,
        age: TimeInterval
    ) -> PersistentAgentInfo {
        PersistentAgentInfo(
            id: id, isAlive: alive, logBytes: 10,
            meta: PersistentAgentMeta(
                workingDirectory: folder, title: "app", createdAt: Date(timeIntervalSinceNow: -age),
                permissionMode: mode, hibernatedAt: hibernated ? Date() : nil
            )
        )
    }

    @Test("Sin agentes del proyecto se crea uno con el modo de los ajustes")
    func createsWhenNone() {
        let other = agent(folder: "/srv/otro", alive: true, age: 10)
        let plan = ShortcutAgentPlanner.plan(agents: [other], workingDirectory: folder, newAgentMode: .plan)
        #expect(plan == .create(.plan))
        #expect(plan.startsClaude)
        #expect(plan.permissionMode == .plan)
    }

    @Test("Se reutiliza el más reciente en marcha aunque haya uno parado más nuevo")
    func reusesNewestAlive() {
        let oldAlive = agent(alive: true, age: 500)
        let newerAlive = agent(alive: true, age: 100)
        let newestStopped = agent(alive: false, age: 10)
        let plan = ShortcutAgentPlanner.plan(
            agents: [oldAlive, newestStopped, newerAlive], workingDirectory: folder, newAgentMode: .default
        )
        #expect(plan == .reuse(newerAlive))
        #expect(!plan.startsClaude)
    }

    @Test("Sin ninguno en marcha se reanuda el más reciente (parado o en reposo)")
    func resumesNewest() {
        let older = agent(alive: false, age: 500)
        let hibernated = agent(alive: false, hibernated: true, age: 50)
        let plan = ShortcutAgentPlanner.plan(agents: [older, hibernated], workingDirectory: folder, newAgentMode: .default)
        #expect(plan == .resume(hibernated))
        #expect(plan.startsClaude)
    }

    @Test("Un agente vivo marcado en reposo se está parando: no cuenta como en marcha")
    func hibernatingAliveIsNotReused() {
        let stopping = agent(alive: true, hibernated: true, age: 10)
        let plan = ShortcutAgentPlanner.plan(agents: [stopping], workingDirectory: folder, newAgentMode: .default)
        #expect(plan == .resume(stopping))
    }

    @Test("La barra final de la carpeta no cambia de proyecto")
    func trailingSlash() {
        let alive = agent(folder: "/srv/app/", alive: true, age: 10)
        #expect(ShortcutAgentPlanner.plan(agents: [alive], workingDirectory: "/srv/app", newAgentMode: .default) == .reuse(alive))
        #expect(ShortcutAgentPlanner.normalized("/") == "/")
    }

    @Test("Modo declarado: sin modo es «preguntar», uno desconocido es nil")
    func declaredMode() {
        #expect(agent(alive: true, mode: nil, age: 1).meta.permissionMode == nil)
        #expect(ShortcutAgentPlanner.declaredMode(of: agent(alive: true, mode: nil, age: 1).meta) == .default)
        #expect(ShortcutAgentPlanner.declaredMode(of: agent(alive: true, mode: "yolo", age: 1).meta) == nil)
        #expect(ShortcutAgentPlan.reuse(agent(alive: true, mode: "acceptEdits", age: 1)).permissionMode == .acceptEdits)
    }

    @Test("Se confirma en modos que actúan solos o desconocidos, salvo permiso explícito")
    func confirmation() {
        #expect(ShortcutAgentPlanner.requiresConfirmation(mode: .bypassPermissions, allowsUnconfirmed: false))
        #expect(ShortcutAgentPlanner.requiresConfirmation(mode: .acceptEdits, allowsUnconfirmed: false))
        #expect(ShortcutAgentPlanner.requiresConfirmation(mode: nil, allowsUnconfirmed: false))
        #expect(!ShortcutAgentPlanner.requiresConfirmation(mode: .default, allowsUnconfirmed: false))
        #expect(!ShortcutAgentPlanner.requiresConfirmation(mode: .plan, allowsUnconfirmed: false))
        #expect(!ShortcutAgentPlanner.requiresConfirmation(mode: .bypassPermissions, allowsUnconfirmed: true))
        #expect(ShortcutAgentPlanner.modeTitle(nil) == "Desconocido")
    }

    @Test("La opción «sin confirmar» está desactivada por defecto")
    func preferenceDefaultsOff() throws {
        let suite = "argos.tests.shortcuts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ShortcutPreferences.allowsUnconfirmed(defaults: defaults))
        defaults.set(true, forKey: ShortcutPreferences.allowsUnconfirmedKey)
        #expect(ShortcutPreferences.allowsUnconfirmed(defaults: defaults))
    }

    @Test("Sin memoria o con demasiados agentes no se arranca otro; reutilizar sí se puede")
    func capacity() {
        let create = ShortcutAgentPlan.create(.default)
        let low = AgentLaunchGuard.minimumFreeMemoryKB - 1
        #expect(ShortcutAgentPlanner.capacityRefusal(plan: create, freeMemoryKB: low, liveAgents: 0) != nil)
        #expect(ShortcutAgentPlanner.capacityRefusal(plan: create, freeMemoryKB: nil, liveAgents: AgentLaunchGuard.maxLiveAgents) != nil)
        #expect(ShortcutAgentPlanner.capacityRefusal(plan: create, freeMemoryKB: nil, liveAgents: 0) == nil)
        let reuse = ShortcutAgentPlan.reuse(agent(alive: true, age: 1))
        #expect(ShortcutAgentPlanner.capacityRefusal(plan: reuse, freeMemoryKB: low, liveAgents: 99) == nil)
    }

    @Test("El encargo se recorta y no puede estar vacío ni ser enorme")
    func taskValidation() throws {
        #expect(try ShortcutTask.validated("  arregla el login \n") == "arregla el login")
        #expect(throws: ShortcutError.emptyTask) { try ShortcutTask.validated(" \n ") }
        let huge = String(repeating: "a", count: ShortcutTask.maxCharacters + 1)
        #expect(throws: ShortcutError.taskTooLong(ShortcutTask.maxCharacters)) { try ShortcutTask.validated(huge) }
    }
}

@Suite("Atajos: caché de proyectos del dispositivo")
struct ProjectShortcutCacheTests {
    private let serverA = UUID()
    private let serverB = UUID()

    private func project(_ name: String, group: String? = nil, path: String? = nil) -> Project {
        Project(name: name, group: group, path: path ?? "/srv/\(name)")
    }

    @Test("Se guarda por servidor y se sustituye al recargar")
    func updateReplaces() {
        let cache = ProjectShortcutCache.empty
            .updating(serverID: serverA, projects: [project("api"), project("web", group: "tmh")])
            .updating(serverID: serverB, projects: [project("infra")])
            .updating(serverID: serverA, projects: [project("api")])
        #expect(cache.projects(of: serverA).map(\.name) == ["api"])
        #expect(cache.projects(of: serverB).map(\.name) == ["infra"])
        #expect(cache.allProjects.count == 2)
    }

    @Test("El identificador lleva servidor y carpeta, y se puede leer de vuelta")
    func identifierRoundTrip() throws {
        let cache = ProjectShortcutCache.empty.updating(serverID: serverA, projects: [project("web", group: "tmh", path: "/home/u/a|b")])
        let cached = try #require(cache.projects(of: serverA).first)
        #expect(cached.displayName == "tmh/web")
        #expect(cache.project(withID: cached.id) == cached)
        let parsed = try #require(CachedProject.parse(identifier: cached.id))
        #expect(parsed.serverID == serverA && parsed.path == "/home/u/a|b")
        #expect(CachedProject.parse(identifier: "nada") == nil)
        #expect(CachedProject.parse(identifier: "\(serverA.uuidString)|relativa") == nil)
    }

    @Test("Los recientes van primero, sin duplicados, y se olvidan con su proyecto")
    func recents() {
        var cache = ProjectShortcutCache.empty.updating(serverID: serverA, projects: [project("a"), project("b"), project("c")])
        let ids = cache.projects(of: serverA).map(\.id)
        cache = cache.markingUsed(ids[2]).markingUsed(ids[1]).markingUsed(ids[2]).markingUsed("desconocido")
        #expect(cache.recents(limit: 5).map(\.name) == ["c", "b"])
        #expect(cache.suggested().map(\.name) == ["c", "b", "a"])
        cache = cache.updating(serverID: serverA, projects: [project("a"), project("b")])
        #expect(cache.recents(limit: 5).map(\.name) == ["b"])
    }

    @Test("Olvidar un servidor borra sus proyectos y sus recientes")
    func keepingServers() {
        let cache = ProjectShortcutCache.empty
            .updating(serverID: serverA, projects: [project("a")])
            .updating(serverID: serverB, projects: [project("b")])
        let used = cache.markingUsed(cache.projects(of: serverB)[0].id).keepingServers([serverA])
        #expect(used.allProjects.map(\.name) == ["a"])
        #expect(used.recents(limit: 5).isEmpty)
    }

    @Test("Búsqueda sin mayúsculas ni tildes: primero los que empiezan por el texto")
    func matching() {
        let cache = ProjectShortcutCache.empty.updating(
            serverID: serverA, projects: [project("Facturación"), project("api-facturas"), project("web")]
        )
        #expect(cache.matching("factu").map(\.name) == ["Facturación", "api-facturas"])
        #expect(cache.matching("FACTURACION").map(\.name) == ["Facturación"])
        #expect(cache.matching("").count == 3)
    }

    @Test("Tope de proyectos por servidor")
    func cap() {
        let many = (0..<(ProjectShortcutCache.maxProjectsPerServer + 5)).map { project("p\($0)") }
        #expect(ProjectShortcutCache.empty.updating(serverID: serverA, projects: many).allProjects.count
                == ProjectShortcutCache.maxProjectsPerServer)
    }

    @Test("Se guarda y se lee en UserDefaults; ilegible empieza de cero")
    func store() throws {
        let suite = "argos.tests.projectcache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectShortcutCacheStore(suiteName: suite)
        #expect(store.load() == .empty)
        let saved = store.update { $0.updating(serverID: serverA, projects: [project("api")]) }
        #expect(store.load() == saved)
        defaults.set(Data("no es json".utf8), forKey: ProjectShortcutCacheStore.key)
        #expect(store.load() == .empty)
    }
}

@Suite("Atajos y avisos: rutas a un proyecto o un agente")
struct ShortcutRouteTests {
    private let serverID = UUID()
    private let agentID = UUID().uuidString.lowercased()

    @Test("La ruta de un proyecto viaja en userInfo con su pestaña")
    func projectRouteRoundTrip() throws {
        let project = CachedProject(serverID: serverID, name: "web", group: "tmh", path: "/srv/web", sessionName: "tmh/web")
        let route = NotificationRoute.open(project, tab: .changes)
        let decoded = try #require(NotificationRoute(userInfo: route.userInfo))
        #expect(decoded == route)
        #expect(decoded.projectPath == "/srv/web" && decoded.session == "tmh/web" && decoded.tab == .changes)
        #expect(decoded.tab?.detailMode == .changes)
    }

    @Test("Un agente implica la pestaña de agentes")
    func agentRoute() throws {
        let route = NotificationRoute(serverID: serverID, projectPath: "/srv/web", tab: .terminal, agentID: agentID)
        #expect(route.tab == .agent)
        let decoded = try #require(NotificationRoute(userInfo: route.userInfo))
        #expect(decoded.agentID == agentID && decoded.tab == .agent)
    }

    @Test("Lo que no es válido se descarta sin perder el servidor")
    func invalidFieldsDropped() throws {
        let info: [AnyHashable: Any] = [
            "argos.serverID": serverID.uuidString,
            "argos.projectPath": "relativa/../x",
            "argos.agentID": "; rm -rf /",
            "argos.tab": "desconocida",
        ]
        let route = try #require(NotificationRoute(userInfo: info))
        #expect(route.serverID == serverID)
        #expect(route.projectPath == nil && route.agentID == nil && route.tab == nil)
        #expect(NotificationRoute(serverID: serverID, projectPath: "/a\nb").projectPath == nil)
    }

    @Test("Un aviso antiguo (solo servidor y sesión) se sigue leyendo igual")
    func legacyRoute() throws {
        let legacy: [AnyHashable: Any] = ["argos.serverID": serverID.uuidString, "argos.session": "api", "argos.window": 2]
        let route = try #require(NotificationRoute(userInfo: legacy))
        #expect(route == NotificationRoute(serverID: serverID, session: "api", window: 2))
    }

    @Test("Spotlight y acciones rápidas: identificador desconocido no abre nada")
    func routeFromIdentifier() {
        let cache = ProjectShortcutCache.empty.updating(serverID: serverID, projects: [Project(name: "api", path: "/srv/api")])
        let id = CachedProject.identifier(serverID: serverID, path: "/srv/api")
        #expect(NotificationRoute.open(identifier: id, cache: cache)?.projectPath == "/srv/api")
        #expect(NotificationRoute.open(identifier: CachedProject.identifier(serverID: serverID, path: "/otro"), cache: cache) == nil)
    }

    @Test("Las instantáneas de los avisos traen la carpeta del agente")
    func snapshotCarriesFolder() throws {
        let id = UUID().uuidString.lowercased()
        let meta = PersistentAgentMeta(workingDirectory: "/srv/web", title: "web", createdAt: Date())
        let metaB64 = try JSONEncoder.projects.encode(meta).base64EncodedString()
        let line = "\(id)|1|42|\(metaB64)|\(Data("x".utf8).base64EncodedString())"
        let snapshot = try #require(PersistentAgentScript.parseSnapshots(line).first)
        #expect(snapshot.workingDirectory == "/srv/web")
    }
}

@Suite("Conexión perdida en los agentes")
struct AgentConnectionLossTests {
    @Test("Se reconoce la conexión perdida y se explica con «Reanudar»")
    func messages() {
        #expect(AgentConnectionLoss.isConnectionLost(SSHConnectionError.connectionLost))
        #expect(!AgentConnectionLoss.isConnectionLost(SSHConnectionError.notConnected))
        #expect(!AgentConnectionLoss.isConnectionLost(nil))
        #expect(AgentConnectionLoss.conversationMessage(for: SSHConnectionError.connectionLost).contains("Reanudar"))
        #expect(AgentConnectionLoss.conversationMessage(for: ShortcutError.emptyTask) == ShortcutError.emptyTask.userMessage)
    }
}
