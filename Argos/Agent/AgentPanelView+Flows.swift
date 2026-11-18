//
//  AgentPanelView+Flows.swift
//  Argos
//
//  Flujos del panel Agente: preparar (carpeta, instalación, sesión), abrir conversaciones
//  de esta sesión o persistentes (con la guardia de memoria y tope sobre TODOS los agentes
//  del servidor), cerrar según `AgentTabClosePolicy`, reanudar, «Continuar en el servidor»
//  y las acciones explícitas sobre un persistente (reposo, detener, reanudar, recargar).
//  Toda acción del usuario levanta antes el bloqueo de conexión (`resetConnectionHealth`).
//

import AppKit
import SwiftUI

extension AgentPanelView {

    // MARK: - Atajos

    /// Atajos de la barra de menús en modo Agente: ⌘T nueva conversación, ⌘W cerrar la
    /// actual, ⌘1…⌘9 y ⌘⇧[ ⌘⇧] para moverse entre conversaciones.
    var tabActions: TabActions? {
        guard readiness == .ready else { return nil }
        let slots = store.slots(for: handle)
        return TabActions(
            identity: AgentTabIdentity(handle: handle, tabIDs: slots.map(\.id), selectedID: store.selectedSlot(for: handle)?.id),
            newTitle: "Nueva conversación",
            closeTitle: "Cerrar conversación",
            newTab: { newConversationRequested(placement) },
            closeTab: {
                if let slot = store.selectedSlot(for: handle) {
                    requestClose(slot)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            },
            selectTab: { number in
                let slots = store.slots(for: handle)
                if let position = WindowTabs.position(forShortcut: number, count: slots.count) {
                    store.select(slots[position].id, for: handle)
                }
            },
            selectAdjacent: { offset in
                let slots = store.slots(for: handle)
                let current = slots.firstIndex { $0.id == store.selectedSlot(for: handle)?.id } ?? 0
                if let position = WindowTabs.adjacentPosition(current: current, offset: offset, count: slots.count) {
                    store.select(slots[position].id, for: handle)
                }
            },
            newAgent: nil,
            installedAgents: nil
        )
    }

    // MARK: - Cerrar

    /// Cierra la pestaña: un persistente solo se desengancha; una de esta sesión se detiene,
    /// pidiendo confirmación si está trabajando o espera un permiso.
    func requestClose(_ slot: AgentTabSlot) {
        switch slot {
        case .session(let tab):
            requestClose(AgentTabEntry(handle: handle, tab: tab))
        case .persistent:
            store.closeTab(slot.id, for: handle)
        }
    }

    func requestClose(_ entry: AgentTabEntry) {
        switch AgentTabClosePolicy.decide(lifecycle: .session, isBusy: entry.tab.session.isBusy) {
        case .confirmStop:
            closeCandidate = entry
        case .stop, .detach:
            store.closeTab(entry.tab.id, for: entry.handle)
            runPendingOpen()
        }
    }

    /// Tope alcanzado: se pregunta qué cerrar y luego se abre `open`.
    private func askEviction(then open: PendingOpen) {
        pendingOpen = open
        isChoosingEviction = true
    }

    func runPendingOpen() {
        guard let open = pendingOpen else { return }
        pendingOpen = nil
        switch open {
        case .newConversation(let placement):
            Task { await newConversation(placement: placement, force: false) }
        case .resume(let tabID):
            if let tab = store.tabs(for: handle).first(where: { $0.id == tabID }) { resume(tab) }
        case .reopen(let conversation):
            reopen(conversation)
        }
    }

    // MARK: - Reanudar

    func resumeAction(for slot: AgentTabSlot) -> (() -> Void)? {
        switch slot {
        case .session(let tab):
            let canResume = !tab.session.isRunning && tab.session.hasConversation && claudePath != nil
            return canResume ? { resume(tab) } : nil
        case .persistent(let tab):
            guard !tab.session.isAlive, !tab.session.meta.isHibernated else { return nil }
            return { requestResume(tab) }
        }
    }

    /// Reanuda en su pestaña una conversación de esta sesión que terminó.
    private func resume(_ tab: AgentTab) {
        guard let claudePath else { return }
        guard store.capacity == .available else { askEviction(then: .resume(tab.id)); return }
        let command = ClaudeAgentCommand.build(
            claudePath: claudePath, workingDirectory: tab.session.workingDirectory,
            sessionID: tab.session.sessionID, permissionMode: tab.permissionMode, resume: true
        )
        let token = oauthTokenForLaunch
        Task {
            await service.resetConnectionHealth()
            await store.resumeTab(tab.id, for: handle, service: service, command: command, oauthToken: token)
        }
    }

    func reopen(_ conversation: ClosedAgentConversation) {
        guard let claudePath else { return }
        guard store.capacity == .available else { askEviction(then: .reopen(conversation)); return }
        let command = ClaudeAgentCommand.build(
            claudePath: claudePath, workingDirectory: conversation.workingDirectory,
            sessionID: conversation.sessionID, permissionMode: conversation.permissionMode, resume: true
        )
        let token = oauthTokenForLaunch
        Task {
            await service.resetConnectionHealth()
            await store.reopen(conversation, for: handle, service: service, command: command, oauthToken: token)
        }
    }

    /// Reanudar un persistente detenido: con un modo que actúa sin preguntar, se confirma
    /// antes (el modo viene del `meta.json` del servidor, que no es de fiar).
    private func requestResume(_ tab: PersistentAgentTab) {
        if tab.session.meta.resumeRequiresConfirmation {
            resumeCandidate = tab
        } else {
            resumePersistent(tab)
        }
    }

    func resumePersistent(_ tab: PersistentAgentTab) {
        let token = oauthTokenForLaunch
        Task {
            await tab.session.liftConnectionBlock()
            if await tab.session.resume(oauthToken: token) {
                if !tab.session.isAttached { tab.session.attach() }
            } else {
                actionError = tab.session.lastError
            }
            await refreshServerAgents(userInitiated: false)
        }
    }

    /// Con sesión en el servidor el token sobra: no se toca el llavero (evita su aviso).
    var oauthTokenForLaunch: String? {
        authStatus?.loggedIn == true ? nil : KeychainStore.claudeOAuthToken()
    }

    // MARK: - Acciones de la franja

    func perform(_ action: AgentTabInfoBar.Action, on slot: AgentTabSlot) {
        switch (action, slot) {
        case (.continueOnServer, .session(let tab)):
            continueOnServer(tab)
        case (.hibernate, .persistent(let tab)):
            runPersistent(tab) { await $0.hibernateNow() }
        case (.stop, .persistent(let tab)):
            runPersistent(tab) { await $0.stop() }
        case (.resume, .persistent(let tab)):
            requestResume(tab)
        case (.reload, .persistent(let tab)):
            Task {
                await tab.session.liftConnectionBlock()
                tab.session.reload()
            }
        default:
            break
        }
    }

    private func runPersistent(_ tab: PersistentAgentTab, _ action: @escaping (PersistentAgentSession) async -> Bool) {
        Task {
            await tab.session.liftConnectionBlock()
            _ = await action(tab.session)
            await refreshServerAgents(userInitiated: false)
        }
    }

    /// «Continuar en el servidor»: misma conversación, ahora como agente persistente.
    private func continueOnServer(_ tab: AgentTab) {
        guard convertingTabID == nil else { return }
        convertingTabID = tab.id
        let token = oauthTokenForLaunch
        let path = claudePath
        Task {
            defer { convertingTabID = nil }
            await service.resetConnectionHealth()
            do {
                try await store.continueOnServer(tab.id, for: handle, service: service, oauthToken: token, claudePath: path)
            } catch {
                Log.agent.error("No se pudo pasar la conversación al servidor: \(error.localizedDescription, privacy: .private)")
                actionError = "No se pudo continuar en el servidor: \(error.userMessage)\n"
                    + "La conversación sigue aquí, detenida: puedes reanudarla en esta sesión."
            }
        }
    }

    // MARK: - Agentes del servidor

    /// Relee los persistentes del servidor (lista «En el servidor» y bandeja).
    func refreshServerAgents(userInitiated: Bool) async {
        isRefreshingAgents = true
        defer { isRefreshingAgents = false }
        if userInitiated { await service.resetConnectionHealth() }
        await store.watch.refresh(serverID: handle.serverID, service: service, background: !userInitiated)
    }

    /// Tras «Detener todos» o «Hibernar»: el estado real de las pestañas abiertas.
    func refreshAfterServerChange() async {
        for (tabHandle, tab) in store.persistentTabs where tabHandle.serverID == handle.serverID {
            await tab.session.refreshInfo()
        }
        await refreshServerAgents(userInitiated: false)
    }

    func openServerAgent(_ agent: PersistentAgentOverview) {
        Task { await service.resetConnectionHealth() }
        store.openPersistent(agent.info, for: handle, service: service)
    }

    func startLogin() {
        guard let claudePath else { return }
        setupPurpose = .login(command: "\(ShellQuoting.singleQuoted(claudePath)) auth login --claudeai")
    }
}
