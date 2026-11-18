//
//  AgentPanelView+Launch.swift
//  Argos
//
//  Preparar el panel (carpeta, instalación y sesión de Claude) y abrir conversaciones
//  nuevas, «solo en esta sesión» o «en el servidor».
//

import SwiftUI

extension AgentPanelView {

    /// Resuelve carpeta, instalación y sesión. Si ya hay pestañas (o el servidor ya se
    /// comprobó), se muestran AL INSTANTE y se verifica en segundo plano.
    /// `userInitiated` («Reintentar», «Comprobar de nuevo», al cerrar una hoja): levanta el
    /// bloqueo de conexión; la aparición automática del panel lo respeta.
    func prepare(userInitiated: Bool = false) async {
        if userInitiated { await service.resetConnectionHealth() }
        let slots = store.slots(for: handle)
        let knownFolder = projectPath ?? slots.first?.conversation.workingDirectory
        let cached = store.readinessCache[handle.serverID]
        let showsInstantly = knownFolder != nil && (cached != nil || !slots.isEmpty)
        if showsInstantly {
            adoptFolder(knownFolder)
            if let cached {
                claudePath = cached.claudePath
                authStatus = cached.authStatus
            }
            readiness = .ready
        } else {
            readiness = .checking
        }
        let serverID = handle.serverID
        Task { await store.cleanUpOrphans(serverID: serverID, service: service) }
        do {
            try await verify(showsInstantly: showsInstantly)
        } catch {
            if showsInstantly && !slots.isEmpty {
                Log.agent.notice("No se pudo verificar Claude: \(error.localizedDescription, privacy: .private)")
            } else {
                readiness = .failed(error.userMessage)
            }
        }
    }

    private func adoptFolder(_ path: String?) {
        guard folder != path, let path else { return }
        folder = path
        placement = AgentLaunchPreferences.placement(serverID: handle.serverID, workingDirectory: path)
    }

    /// Comprueba carpeta, instalación y sesión. Con pestañas abiertas, un problema no
    /// las esconde (siguen usables); sin pestañas, se muestra la tarjeta que toque.
    private func verify(showsInstantly: Bool) async throws {
        let hasTabs = !store.slots(for: handle).isEmpty
        if folder == nil {
            if let projectPath {
                adoptFolder(projectPath)
            } else {
                adoptFolder(try await service.sessionFirstPanePaths()[handle.sessionID])
            }
        }
        guard folder != nil else { readiness = .noFolder; return }

        let path = try await service.locateClaude()
        claudePath = path
        guard let path else {
            store.readinessCache[handle.serverID] = nil
            if !hasTabs { readiness = .notInstalled }
            return
        }
        let auth = try await service.claudeAuthStatus()
        authStatus = auth
        guard auth?.loggedIn == true || KeychainStore.hasClaudeOAuthToken() else {
            store.readinessCache[handle.serverID] = nil
            if !hasTabs { readiness = .loggedOut }
            return
        }
        store.readinessCache[handle.serverID] = AgentServerReadiness(claudePath: path, authStatus: auth)
        if !showsInstantly || readiness != .ready { readiness = .ready }
        await refreshServerAgents(userInitiated: false)
        if shouldStartAutomatically {
            await newConversation(placement: .session, force: false, userInitiated: false)
        }
    }

    /// La primera conversación se abre sola solo si es «de esta sesión» y no hay nada que
    /// mirar: nunca se lanza un agente persistente sin pedirlo, y si la carpeta ya tiene
    /// agentes en el servidor se deja elegir.
    private var shouldStartAutomatically: Bool {
        store.slots(for: handle).isEmpty && placement == .session && folderAgents.isEmpty
    }

    /// El usuario pidió una conversación nueva (+, ⌘T o el menú del +). Elegir en el menú
    /// cambia lo que se recuerda para el proyecto.
    func newConversationRequested(_ choice: AgentConversationPlacement) {
        if choice != placement, let folder {
            placement = choice
            AgentLaunchPreferences.setPlacement(choice, serverID: handle.serverID, workingDirectory: folder)
        }
        Task { await newConversation(placement: choice, force: false) }
    }

    /// Abre una conversación nueva (nueva pestaña) en la carpeta del proyecto. Antes mira
    /// la memoria libre y cuántos agentes hay vivos en TODO el servidor (`force`: el
    /// usuario ya lo aceptó). Pedida por el usuario levanta el bloqueo de conexión.
    func newConversation(placement: AgentConversationPlacement, force: Bool, userInitiated: Bool = true) async {
        guard let folder, let claudePath, !isStartingTab else { return }
        if placement == .session, store.capacity != .available {
            pendingOpen = .newConversation(placement)
            isChoosingEviction = true
            return
        }
        isStartingTab = true
        defer { isStartingTab = false }
        if userInitiated { await service.resetConnectionHealth() }
        if !force, case .warning(let title, let message) = await launchAssessment() {
            launchWarning = LaunchWarning(title: title, message: message, placement: placement)
            return
        }
        readiness = .ready
        let mode = AgentPermissionPreferences.effectiveMode(serverID: handle.serverID, workingDirectory: folder)
        switch placement {
        case .session:
            openSessionConversation(folder: folder, claudePath: claudePath, mode: mode)
        case .server:
            await openServerConversation(folder: folder, claudePath: claudePath, mode: mode)
        }
    }

    private func openSessionConversation(folder: String, claudePath: String, mode: ClaudeAgentCommand.PermissionMode) {
        let sessionID = UUID().uuidString.lowercased()
        let command = ClaudeAgentCommand.build(
            claudePath: claudePath, workingDirectory: folder, sessionID: sessionID, permissionMode: mode
        )
        store.newTab(
            for: handle, service: service, command: command, workingDirectory: folder,
            oauthToken: oauthTokenForLaunch, permissionMode: mode, sessionID: sessionID
        )
    }

    private func openServerConversation(folder: String, claudePath: String, mode: ClaudeAgentCommand.PermissionMode) async {
        do {
            try await store.launchPersistent(
                for: handle, service: service, folder: folder, title: title,
                permissionMode: mode, oauthToken: oauthTokenForLaunch, claudePath: claudePath
            )
        } catch {
            Log.agent.error("No se pudo crear el agente en el servidor: \(error.localizedDescription, privacy: .private)")
            actionError = String(localized: "No se pudo crear el agente en el servidor: \(error.userMessage)")
        }
    }

    /// Guardia de memoria y tope con TODOS los agentes vivos del servidor (de cualquier
    /// proyecto o dispositivo). Si no se puede saber, no se bloquea.
    private func launchAssessment() async -> AgentLaunchGuard.Assessment {
        do {
            let inventory = try await service.serverAgentInventory()
            return AgentLaunchGuard.assess(freeMemoryKB: inventory.freeMemoryKB, liveAgents: inventory.liveAgents.count)
        } catch {
            Log.agent.notice("No se pudo comprobar la memoria antes de abrir el agente: \(error.localizedDescription, privacy: .private)")
            return .ok
        }
    }
}
