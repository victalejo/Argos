//
//  AgentPanelView+Dialogs.swift
//  Argos
//
//  Hojas y confirmaciones del panel Agente (separadas para que la vista principal siga
//  siendo pequeña y el compilador la compruebe a tiempo).
//

import SwiftUI

extension AgentPanelView {

    func withSheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { setupPurpose.map(SetupRequest.init) },
                set: { setupPurpose = $0?.purpose }
            )) { request in
                ClaudeSetupSheet(service: service, serverName: serverName, purpose: request.purpose) { _ in
                    setupPurpose = nil
                    Task { await prepare(userInitiated: true) }
                }
            }
            .sheet(isPresented: $showTokenSheet) {
                AgentTokenSheet {
                    showTokenSheet = false
                    Task { await prepare(userInitiated: true) }
                }
            }
            .sheet(isPresented: $showsServerAgents) {
                ServerAgentsSheet(
                    serverName: serverName,
                    service: service,
                    onChange: { Task { await refreshAfterServerChange() } },
                    onClose: { showsServerAgents = false }
                )
            }
            .alert("No se pudo completar", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
    }

    func withDialogs<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog(
                "¿Cerrar esta conversación?",
                isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } }),
                titleVisibility: .visible,
                presenting: closeCandidate
            ) { entry in
                Button("Cerrar y detener Claude", role: .destructive) {
                    store.closeTab(entry.tab.id, for: entry.handle)
                    runPendingOpen()
                }
                Button("Cancelar", role: .cancel) { pendingOpen = nil }
            } message: { entry in
                Text(closeMessage(entry))
            }
            .confirmationDialog(
                "Ya hay \(AgentSessionStore.maxLiveSessions) conversaciones abiertas",
                isPresented: $isChoosingEviction,
                titleVisibility: .visible
            ) {
                ForEach(store.allTabs.filter { $0.tab.session.isRunning }) { entry in
                    Button("Cerrar «\(entry.tab.title)» (\(entry.handle.sessionID))", role: .destructive) {
                        requestClose(entry)
                    }
                }
                Button("Cancelar", role: .cancel) { pendingOpen = nil }
            } message: {
                Text(String(localized: "Cada una es un Claude en el servidor (~\(ResourceFormat.gigabytes(0.5))). Elige cuál cerrar para abrir otra; podrás reanudarla después. Los agentes que siguen en el servidor no cuentan aquí."))
            }
            .modifier(AgentLaunchDialogs(panel: self))
    }

    private func closeMessage(_ entry: AgentTabEntry) -> String {
        if entry.tab.session.state.pendingPermission != nil {
            return String(localized: "Claude espera tu permiso en «\(entry.tab.title)». Si la cierras, se detiene sin terminar. Para que siga sin esta ventana, usa «Continuar en el servidor» cuando termine.")
        }
        return String(localized: "Claude está trabajando en «\(entry.tab.title)». Si la cierras, se detiene a medias.")
    }
}

/// Avisos al crear o reanudar un agente (guardia de memoria/tope y modo de permisos).
private struct AgentLaunchDialogs: ViewModifier {
    let panel: AgentPanelView

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                panel.launchWarning?.title ?? "",
                isPresented: Binding(get: { panel.launchWarning != nil }, set: { if !$0 { panel.launchWarning = nil } }),
                titleVisibility: .visible,
                presenting: panel.launchWarning
            ) { warning in
                Button("Crear de todos modos") {
                    Task { await panel.newConversation(placement: warning.placement, force: true) }
                }
                Button("Ver agentes del servidor") { panel.showsServerAgents = true }
                Button("Cancelar", role: .cancel) {}
            } message: { warning in
                Text(warning.message)
            }
            .confirmationDialog(
                "¿Reanudar en «\(panel.resumeCandidate?.session.meta.resolvedPermissionMode.title ?? "")»?",
                isPresented: Binding(get: { panel.resumeCandidate != nil }, set: { if !$0 { panel.resumeCandidate = nil } }),
                titleVisibility: .visible,
                presenting: panel.resumeCandidate
            ) { tab in
                Button("Reanudar en «\(tab.session.meta.resolvedPermissionMode.title)»", role: .destructive) {
                    panel.resumePersistent(tab)
                }
                Button("Cancelar", role: .cancel) {}
            } message: { tab in
                Text(String(localized: "El servidor indica que este agente usa este modo. \(tab.session.meta.resolvedPermissionMode.detail) Si no lo elegiste tú, no lo reanudes: abre otra conversación."))
            }
    }
}
