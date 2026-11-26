//
//  SessionsColumnSheets.swift
//  Argos
//
//  Hojas y confirmaciones de la columna central: formularios de proyecto, envíos,
//  importar, detener/quitar; renombrar y matar sesiones, enviar comando y los errores
//  de operaciones sin formulario propio.
//

import SwiftUI

/// Hojas y confirmaciones de proyectos.
struct SessionsColumnProjectSheets: ViewModifier {
    let model: ArgosAppModel
    @Binding var projectForm: ProjectFormRequest?
    @Binding var projectSync: ProjectSyncRequest?
    @Binding var importServer: Server?
    @Binding var projectConfirmation: ProjectConfirmation?

    func body(content: Content) -> some View {
        content
            .sheet(item: $projectForm) { request in
                if let vm = model.vms[request.server.id] {
                    if case .worktrees(_, let project) = request {
                        WorktreesSheet(project: project, vm: vm)
                    } else if case .tasks(_, let project) = request {
                        ClaudeTasksSheet(project: project, vm: vm)
                    } else {
                        ProjectFormSheet(request: request, vm: vm)
                    }
                }
            }
            .sheet(item: $projectSync) { request in
                if let vm = model.vms[request.server.id] {
                    ProjectSyncSheet(
                        request: request,
                        vm: vm,
                        closeLiveViews: { project in
                            let handle = SessionHandle(serverID: request.server.id, sessionID: project.sessionName)
                            model.terminalStore.close(handle)
                            model.agentStore.closeAll(for: handle)
                        },
                        onClose: { projectSync = nil }
                    )
                }
            }
            .sheet(item: $importServer) { server in
                if let vm = model.vms[server.id] {
                    ImportProjectsSheet(server: server, vm: vm)
                }
            }
            .confirmationDialog(
                projectConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { projectConfirmation != nil },
                    set: { if !$0 { projectConfirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: projectConfirmation
            ) { confirmation in
                Button(confirmation.actionLabel, role: .destructive) { perform(confirmation) }
                Button("Cancelar", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
    }

    private func perform(_ confirmation: ProjectConfirmation) {
        guard let vm = model.vms[confirmation.server.id] else { return }
        let serverID = confirmation.server.id
        Task {
            do {
                switch confirmation {
                case .stop(_, let project):
                    // Cierra antes el terminal (para que no muestre una sesión muerta) y sus
                    // agentes de Claude (cada uno es un proceso que ocupa memoria).
                    let handle = SessionHandle(serverID: serverID, sessionID: project.sessionName)
                    model.terminalStore.close(handle)
                    model.agentStore.closeAll(for: handle)
                    try await vm.stopProject(project)
                case .remove(_, let project):
                    try await vm.removeProject(project)
                case .stopBackground(_, let projects):
                    for project in projects {
                        model.agentStore.closeAll(for: SessionHandle(serverID: serverID, sessionID: project.sessionName))
                    }
                    let failed = await vm.stopSessions(named: projects.map(\.sessionName))
                    if !failed.isEmpty {
                        vm.operationError = String(localized: "No se pudieron detener: \(failed.joined(separator: ", "))")
                    }
                }
            } catch {
                vm.operationError = error.userMessage
            }
        }
    }
}

/// Hojas de sesiones sueltas, enviar comando y alerta de errores de operación.
struct SessionsColumnSessionSheets: ViewModifier {
    let model: ArgosAppModel
    @Binding var renameTarget: SessionAction?
    @Binding var killTarget: SessionAction?
    @Binding var isShowingBroadcast: Bool
    let broadcastTargets: [BroadcastTarget]
    let broadcastPreselect: Set<SessionHandle>

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingBroadcast) {
                SendCommandSheet(
                    targets: broadcastTargets,
                    initialSelection: broadcastPreselect,
                    onClose: { isShowingBroadcast = false }
                )
            }
            .sheet(item: $renameTarget) { action in
                SessionNameSheet(mode: .rename(current: action.session.name)) { newName in
                    if let vm = model.vms[action.server.id] {
                        try await vm.renameSession(action.session, to: newName)
                    }
                }
            }
            .confirmationDialog(
                killTarget.map { "¿Matar la sesión '\($0.session.name)'?" } ?? "¿Matar la sesión?",
                isPresented: Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } }),
                titleVisibility: .visible,
                presenting: killTarget
            ) { action in
                Button("Matar", role: .destructive) {
                    Task {
                        if let vm = model.vms[action.server.id] { await vm.kill(action.session) }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text("Se cerrará y se perderá todo lo que corra en ella.")
            }
            // Errores de operaciones sin formulario propio (matar, detener…).
            .alert(
                "No se pudo completar la operación",
                isPresented: operationErrorBinding,
                presenting: vmWithError?.operationError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private var orderedVMs: [SessionsViewModel] {
        model.store.servers.compactMap { model.vms[$0.id] }
    }

    /// Primer view model con un error de operación pendiente.
    private var vmWithError: SessionsViewModel? {
        orderedVMs.first { $0.operationError != nil }
    }

    /// Visible si algún view model tiene error; al descartar, se limpian todos.
    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { orderedVMs.contains { $0.operationError != nil } },
            set: { presented in
                if !presented { orderedVMs.forEach { $0.operationError = nil } }
            }
        )
    }
}
