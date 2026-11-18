//
//  ShortcutAgentSender.swift
//  ArgosiOS
//
//  La parte de red del atajo «Pedir a Claude»: conecta con el servidor del proyecto, decide
//  a qué agente persistente mandar el encargo (`ShortcutAgentPlanner`) y se lo escribe por
//  la entrada estándar. No necesita la app abierta: el agente sigue en el servidor.
//
//  Va con plazos cortos (iOS da poco tiempo a un atajo en segundo plano) y con una conexión
//  propia que se cierra al terminar, sin tocar la de la app si estuviera abierta.
//

import Foundation

@MainActor
enum ShortcutAgentSender {
    /// Conectar, listar agentes y, si toca arrancar uno, comprobar memoria y sesión.
    static let prepareTimeout: Duration = .seconds(12)
    /// Escribir a un agente en marcha.
    static let sendTimeout: Duration = .seconds(10)
    /// Arrancar (o reanudar) un `claude` y escribirle.
    static let startAndSendTimeout: Duration = .seconds(16)

    struct Target: Sendable {
        let server: Server
        let project: CachedProject
    }

    struct Prepared: Sendable {
        let target: Target
        let plan: ShortcutAgentPlan
        let service: SSHService
    }

    /// Proyecto y servidor de la caché (sin red).
    static func target(forProjectID id: String) throws -> Target {
        guard let project = ProjectShortcutCacheStore().load().project(withID: id) else {
            throw ShortcutError.projectNotFound
        }
        guard let server = ServerStore().server(withID: project.serverID) else { throw ShortcutError.serverNotFound }
        guard !ImportedKeyStore.needsImport(server) else {
            throw ShortcutError.sendFailed("este iPhone aún no tiene la clave de «\(server.name)». Recíbela desde el Mac.")
        }
        return Target(server: server, project: project)
    }

    /// Conecta y decide qué hacer. Lanza si no se puede (sin red, sin memoria, sin Claude).
    static func prepare(_ target: Target) async throws -> Prepared {
        let service = target.server.makeService()
        do {
            return try await Deadline.value(within: prepareTimeout, timeoutError: { ShortcutError.timedOut }) {
                try await plan(target, service: service)
            }
        } catch {
            close(service)
            throw error
        }
    }

    /// Manda el encargo según el plan y cierra la conexión.
    static func send(_ text: String, prepared: Prepared) async throws {
        defer { close(prepared.service) }
        let timeout = prepared.plan.startsClaude ? startAndSendTimeout : sendTimeout
        try await Deadline.value(within: timeout, timeoutError: { ShortcutError.timedOut }) { @MainActor in
            try await deliver(text, prepared: prepared)
        }
        AgentNotifier.shared.didUseAgents(on: prepared.target.server)
        ProjectShortcutIndex.markUsed(prepared.target.project.id)
    }

    /// Se abandona la conexión sin esperar (una colgada tampoco respondería al cierre).
    static func close(_ service: SSHService) {
        Task { await service.disconnect() }
    }

    // MARK: - Pasos

    private static func plan(_ target: Target, service: SSHService) async throws -> Prepared {
        let agents = try await PersistentAgentSession.list(service: service)
        let folder = target.project.path
        let plan = ShortcutAgentPlanner.plan(
            agents: agents,
            workingDirectory: folder,
            newAgentMode: AgentPermissionPreferences.effectiveMode(serverID: target.server.id, workingDirectory: folder)
        )
        if plan.startsClaude {
            let inventory = try await service.serverAgentInventory()
            if let refusal = ShortcutAgentPlanner.capacityRefusal(
                plan: plan, freeMemoryKB: inventory.freeMemoryKB, liveAgents: inventory.liveAgents.count
            ) {
                throw ShortcutError.capacity(refusal)
            }
            try await checkClaude(service)
        }
        return Prepared(target: target, plan: plan, service: service)
    }

    /// Para arrancar un `claude` hace falta que esté instalado y con sesión (o token).
    private static func checkClaude(_ service: SSHService) async throws {
        guard let status = try await service.claudeAuthStatus() else { throw ShortcutError.claudeMissing }
        guard status.loggedIn || KeychainStore.hasClaudeOAuthToken() else { throw ShortcutError.claudeLoggedOut }
    }

    private static func deliver(_ text: String, prepared: Prepared) async throws {
        let session: PersistentAgentSession
        switch prepared.plan {
        case .reuse(let info), .resume(let info):
            session = PersistentAgentSession(service: prepared.service, info: info)
        case .create(let mode):
            session = try await PersistentAgentSession.launch(
                service: prepared.service,
                workingDirectory: prepared.target.project.path,
                title: prepared.target.project.name,
                permissionMode: mode
            )
        }
        // El encargo nunca va en la línea de comandos (se vería en `ps` del servidor).
        session.sendsOnlyViaStdin = true
        // La confirmación por el modo ya se resolvió en el atajo: reanudar está permitido.
        switch await session.send(text, confirmedResume: true) {
        case .sent:
            return
        case .needsResumeConfirmation, .failed:
            throw ShortcutError.sendFailed(session.lastError ?? "el agente no respondió.")
        }
    }
}
