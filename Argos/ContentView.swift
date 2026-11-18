//
//  ContentView.swift
//  Argos
//
//  La ventana (única) de la app: NavigationSplitView de 3 columnas —
//  servidores → proyectos y sesiones de TODOS los servidores → terminal en vivo.
//  No es dueña de nada: observa `ArgosAppModel`, que vive en el delegado de la app y
//  sobrevive a cerrar y reabrir la ventana. Aquí solo están las hojas y confirmaciones.
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: ArgosAppModel

    @State private var serverFormMode: ServerFormSheet.Mode?
    @State private var serverToDelete: Server?
    @State private var hostKeyToForget: Server?
    /// Servidor en el que se va a activar el indicador de Claude Code (confirmación).
    @State private var claudeHooksServer: Server?
    /// Hojas con el servicio capturado al abrir: no dependen de `vms` mientras están
    /// abiertas (si la búsqueda fallaba, SwiftUI mostraba una hoja vacía imposible de cerrar).
    @State private var transferServer: ServerSheetTarget?
    @State private var devicesServer: ServerSheetTarget?
    /// Resultado de activar el indicador (alerta).
    @State private var claudeHooksResult: String?
    /// Fallo al guardar un servidor (el Llavero no aceptó el secreto).
    @State private var saveError: String?
    @State private var quickSwitcher = QuickSwitcher.shared
    @State private var showSSHConfig = false

    /// Último servidor seleccionado (persistido entre arranques).
    @SceneStorage("selectedServerID") private var persistedServerID = ""

    var body: some View {
        workspace
            .modifier(ServerDialogs(
                model: model,
                serverToDelete: $serverToDelete,
                hostKeyToForget: $hostKeyToForget,
                claudeHooksServer: $claudeHooksServer,
                claudeHooksResult: $claudeHooksResult,
                saveError: $saveError
            ))
            .portRequestAlerts(model)
    }

    private var workspace: some View {
        NavigationSplitView {
            ServerSidebar(model: model, onRequest: handle)
        } content: {
            if model.store.servers.isEmpty {
                FirstServerView { serverFormMode = .add }
            } else {
                SessionsColumn(model: model)
            }
        } detail: {
            detail
        }
        .tint(ArgosTheme.controlAccent)
        .frame(minWidth: 1040, minHeight: 640)
        .onAppear {
            model.start()
            if model.selectedServerID == nil {
                model.selectedServerID = restoredServerID() ?? model.store.servers.first?.id
            }
            model.loadSelectedIfNeeded()
        }
        .onChange(of: model.selectedSession) { _, handle in model.didSelect(handle) }
        .toolbar {
            ToolbarItem(placement: .navigation) { AttentionToolbarButton(model: model) }
        }
        .onChange(of: model.selectedServerID) { _, newValue in
            persistedServerID = newValue?.uuidString ?? ""
            model.loadSelectedIfNeeded()
        }
        .modifier(serverSheets)
        // Switcher en un subview propio para no competir con el sheet del formulario.
        .background(
            Color.clear.sheet(isPresented: $quickSwitcher.isPresented) {
                QuickSwitcherView(
                    items: quickSwitchItems,
                    onSelect: { handle in
                        model.selectedServerID = handle.serverID
                        model.selectedSession = handle
                        quickSwitcher.isPresented = false
                    },
                    onCancel: { quickSwitcher.isPresented = false }
                )
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let handle = model.selectedSession,
           let vm = model.vms[handle.serverID],
           vm.session(withID: handle.sessionID) != nil || vm.project(forSession: handle.sessionID) != nil {
            ProjectDetailView(model: model, handle: handle, vm: vm)
        } else {
            WelcomeWorkspaceView(canSearch: !quickSwitchItems.isEmpty) { quickSwitcher.present() }
        }
    }

    private var serverSheets: ServerSheets {
        ServerSheets(
            model: model,
            serverFormMode: $serverFormMode,
            transferServer: $transferServer,
            devicesServer: $devicesServer,
            showSSHConfig: $showSSHConfig,
            saveError: $saveError
        )
    }

    private func handle(_ request: ServerSidebarRequest) {
        switch request {
        case .add: serverFormMode = .add
        case .importSSHConfig: showSSHConfig = true
        case .edit(let server): serverFormMode = .edit(server)
        case .transfer(let server): transferServer = model.sheetTarget(for: server)
        case .devices(let server): devicesServer = model.sheetTarget(for: server)
        case .claudeHooks(let server): claudeHooksServer = server
        case .doctor(let server): model.presentDoctor(for: server)
        case .forgetHostKey(let server): hostKeyToForget = server
        case .delete(let server): serverToDelete = server
        }
    }

    /// Servidor persistido de un arranque anterior, si todavía existe.
    private func restoredServerID() -> Server.ID? {
        guard let uuid = UUID(uuidString: persistedServerID) else { return nil }
        return model.store.server(withID: uuid)?.id
    }

    /// Todas las sesiones (de todos los servidores) para el cambiador rápido (⌘K).
    private var quickSwitchItems: [QuickSwitchItem] {
        model.store.servers.flatMap { server in
            (model.vms[server.id]?.sessions ?? []).map { session in
                QuickSwitchItem(
                    handle: SessionHandle(serverID: server.id, sessionID: session.id),
                    serverName: server.name,
                    sessionName: session.name
                )
            }
        }
    }
}

// MARK: - ServerFormSheet.Mode como Identifiable para .sheet(item:)

extension ServerFormSheet.Mode: Identifiable {
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let server): return "edit-\(server.id.uuidString)"
        }
    }

    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}

// MARK: - Previews

#if DEBUG
extension TmuxSession {
    static let samples: [TmuxSession] = [
        TmuxSession(name: "main",    windowCount: 3, isAttached: true,  createdAt: .now.addingTimeInterval(-3600)),
        TmuxSession(name: "deploy",  windowCount: 1, isAttached: false, createdAt: .now.addingTimeInterval(-86_400)),
        TmuxSession(name: "logs",    windowCount: 5, isAttached: false, createdAt: .now.addingTimeInterval(-120))
    ]
}
#endif
