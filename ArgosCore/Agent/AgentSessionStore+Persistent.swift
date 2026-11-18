//
//  AgentSessionStore+Persistent.swift
//  Argos
//
//  Pestañas de agentes PERSISTENTES en el panel Agente del Mac: abrir uno del servidor
//  (creado aquí, en el iPhone/iPad, Android u otro Mac), crear uno nuevo y «Continuar en el
//  servidor» una conversación de esta sesión. Cada agente se abre en UNA sola pestaña (dos
//  enganches al mismo log no aportan nada). Cerrarla solo desengancha.
//

import Foundation

/// ¿Se puede pasar al servidor una conversación de esta sesión? (lógica pura)
enum AgentConversion {
    static func blocker(hasConversation: Bool, isBusy: Bool, sessionID: String) -> AgentConversionError? {
        guard hasConversation, PersistentAgentScript.isValidID(sessionID) else { return .nothingToContinue }
        return isBusy ? .busy : nil
    }
}

extension AgentSessionStore {

    /// Pestañas persistentes con su proyecto.
    var persistentTabs: [(handle: SessionHandle, tab: PersistentAgentTab)] {
        slotsByHandle.flatMap { handle, slots in slots.compactMap(\.persistentTab).map { (handle, $0) } }
    }

    /// Agentes con su pestaña abierta y enganchada, por servidor (lo que el usuario ya ve).
    var viewingPersistent: [Server.ID: Set<String>] {
        var result: [Server.ID: Set<String>] = [:]
        for (handle, tab) in persistentTabs where tab.session.isAttached {
            result[handle.serverID, default: []].insert(tab.session.id)
        }
        return result
    }

    /// Pestaña (y proyecto) del agente `agentID` de un servidor, si está abierta.
    func persistentTab(serverID: Server.ID, agentID: String) -> (handle: SessionHandle, tab: PersistentAgentTab)? {
        persistentTabs.first { $0.handle.serverID == serverID && $0.tab.session.id == agentID }
    }

    /// Abre (o selecciona, si ya está abierto) el agente persistente `info` en una pestaña
    /// del proyecto y se engancha a su log. Devuelve el id de la pestaña.
    @discardableResult
    func openPersistent(_ info: PersistentAgentInfo, for handle: SessionHandle, service: any SSHServicing) -> UUID {
        if let open = persistentTab(serverID: handle.serverID, agentID: info.id) {
            selectedByHandle[open.handle] = open.tab.id
            if !open.tab.session.isAttached { open.tab.session.attach() }
            return open.tab.id
        }
        let session = PersistentAgentSession(service: service, info: info)
        return insertPersistent(session, for: handle, replacing: nil)
    }

    /// Lanza un agente persistente nuevo en `folder` y lo abre en una pestaña.
    @discardableResult
    func launchPersistent(
        for handle: SessionHandle,
        service: any SSHServicing,
        folder: String,
        title: String,
        permissionMode: ClaudeAgentCommand.PermissionMode,
        oauthToken: String?,
        claudePath: String?,
        hibernation: PersistentAgentHibernation = AgentHibernationPreferences.current()
    ) async throws -> UUID {
        let session = try await PersistentAgentSession.launch(
            service: service, workingDirectory: folder, title: title, permissionMode: permissionMode,
            oauthToken: oauthToken, hibernation: hibernation, claudePath: claudePath
        )
        let tabID = insertPersistent(session, for: handle, replacing: nil)
        await watch.refresh(serverID: handle.serverID, service: service)
        return tabID
    }

    /// «Continuar en el servidor»: detiene el `claude` de esta sesión (esperando a que el
    /// servidor lo confirme), y relanza ESA conversación como agente persistente con
    /// `--resume` y su id, en la misma pestaña y sin perder lo que se veía. Si falla, la
    /// pestaña queda como conversación de esta sesión detenida (se puede reanudar aquí).
    func continueOnServer(
        _ tabID: UUID,
        for handle: SessionHandle,
        service: any SSHServicing,
        oauthToken: String?,
        claudePath: String?,
        hibernation: PersistentAgentHibernation = AgentHibernationPreferences.current()
    ) async throws {
        guard let tab = tabs(for: handle).first(where: { $0.id == tabID }), !converting.contains(tabID) else { return }
        let old = tab.session
        if let blocker = AgentConversion.blocker(hasConversation: old.hasConversation, isBusy: old.isBusy, sessionID: old.sessionID) {
            throw blocker
        }
        converting.insert(tabID)
        defer { converting.remove(tabID) }
        let transcript = old.state
        let title = tab.title
        await old.stopAndWait()
        // Nunca reabrirla como conversación de esta sesión: serían dos claude con el mismo id.
        closedByHandle[handle]?.removeAll { $0.sessionID == old.sessionID }
        let session = try await PersistentAgentSession.adopt(
            service: service, sessionID: old.sessionID, workingDirectory: old.workingDirectory,
            title: title, permissionMode: tab.permissionMode, transcript: transcript,
            oauthToken: oauthToken, hibernation: hibernation, claudePath: claudePath
        )
        insertPersistent(session, for: handle, replacing: tabID)
        await watch.refresh(serverID: handle.serverID, service: service)
    }

    /// Pone `session` en una pestaña (en el sitio de `replacing`, o al final), la
    /// selecciona y se engancha.
    @discardableResult
    private func insertPersistent(_ session: PersistentAgentSession, for handle: SessionHandle, replacing: UUID?) -> UUID {
        var slots = slotsByHandle[handle] ?? []
        let tabID: UUID
        if let replacing, let index = slots.firstIndex(where: { $0.id == replacing }) {
            tabID = replacing
            slots[index] = .persistent(PersistentAgentTab(id: replacing, number: slots[index].number, session: session))
        } else {
            tabID = UUID()
            slots.append(.persistent(PersistentAgentTab(id: tabID, number: nextNumber(for: handle), session: session)))
        }
        slotsByHandle[handle] = slots
        selectedByHandle[handle] = tabID
        session.attach()
        watch.markSeen(serverID: handle.serverID, agentID: session.id)
        return tabID
    }
}
