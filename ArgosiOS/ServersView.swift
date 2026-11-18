//
//  ServersView.swift
//  ArgosiOS
//
//  Pantalla inicial: servidores | proyectos | terminal/archivos/agentes. Un único
//  `NavigationSplitView` para iPhone e iPad: en ancho compacto se colapsa en una pila
//  (servidores → proyectos → detalle), así que girar o redimensionar no reconstruye la
//  navegación. La selección vive en `AppNavigation` y se restaura con `@SceneStorage`.
//  Deslizar un servidor permite editarlo o borrarlo.
//

import SwiftUI

struct RootView: View {
    @Environment(ServerHub.self) private var hub
    @SceneStorage("argos.navigation") private var savedNavigation = ""
    @State private var navigation = AppNavigation()
    @State private var restored = false

    private var server: Server? { navigation.serverID.flatMap { hub.store.server(withID: $0) } }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $navigation.compactColumn) {
            ServerList(selection: Binding(
                get: { navigation.serverID },
                set: { navigation.selectServer($0) }
            ))
        } content: {
            if let server {
                ProjectsView(server: server, selection: Binding(
                    get: { navigation.target },
                    set: { navigation.open($0) }
                ))
                .id(server.id)
            } else {
                ContentUnavailableView("Elige un servidor", systemImage: "server.rack")
            }
        } detail: {
            NavigationStack {
                if let server, let target = navigation.target {
                    ProjectScreen(server: server, target: target, mode: $navigation.mode)
                        .id("\(server.id)/\(target.id)")
                } else {
                    ContentUnavailableView("Elige un proyecto", systemImage: "folder")
                }
            }
        }
        .onAppear(perform: restoreOnce)
        .onChange(of: navigation.encoded) { _, encoded in savedNavigation = encoded }
        .onChange(of: hub.store.servers) { _, _ in
            navigation.dropMissingServer { hub.store.server(withID: $0) != nil }
        }
        // Tocar una notificación: elige su servidor; `ProjectsView` abre la sesión.
        .onChange(of: hub.pendingRoute, initial: true) { _, route in
            guard let route, hub.store.server(withID: route.serverID) != nil else { return }
            if navigation.serverID != route.serverID { navigation.selectServer(route.serverID) }
        }
    }

    /// Arranque en frío o escena nueva: vuelve a donde se estaba.
    private func restoreOnce() {
        guard !restored else { return }
        restored = true
        navigation.restore(from: savedNavigation)
        navigation.dropMissingServer { hub.store.server(withID: $0) != nil }
    }
}

/// Lista de servidores con alta (manual o por QR del Mac), edición y borrado. Con
/// `selection` marca el servidor elegido (y en compacto lo abre); sin ella cada fila navega.
struct ServerList: View {
    var selection: Binding<Server.ID?>?
    @Environment(ServerHub.self) private var hub
    @State private var editing: ServerFormView.Mode?
    @State private var pendingDeletion: Server?
    @AppStorage(CloudServerSync.enabledKey) private var cloudSyncEnabled = true
    @AppStorage(AgentPermissionPreferences.globalKey)
    private var agentPermissionMode = AgentPermissionPreferences.fallback.rawValue
    /// Alta desde el QR del Mac (con el código ya leído si llegó por enlace).
    @State private var importing: ImportRequest?
    @State private var linkError: String?

    private struct ImportRequest: Identifiable {
        let id = UUID()
        let transfer: ServerTransfer?
    }

    var body: some View {
        List(selection: selection) {
            ForEach(hub.store.servers) { server in
                row(server)
                .swipeActions(edge: .trailing) {
                    Button("Borrar", systemImage: "trash", role: .destructive) { pendingDeletion = server }
                    Button("Editar", systemImage: "pencil") { editing = .edit(server) }
                        .tint(.indigo)
                }
                .contextMenu {
                    Button("Editar", systemImage: "pencil") { editing = .edit(server) }
                    Button("Borrar", systemImage: "trash", role: .destructive) { pendingDeletion = server }
                }
            }
        }
        .overlay {
            if hub.store.servers.isEmpty {
                ContentUnavailableView {
                    Label("Sin servidores", systemImage: "server.rack")
                } description: {
                    Text("Añade un servidor con SSH y tmux para ver sus proyectos y sesiones.")
                } actions: {
                    Button("Añadir servidor") { editing = .create }
                        .buttonStyle(.borderedProminent)
                    Button("Escanear QR del Mac", systemImage: "qrcode.viewfinder") {
                        importing = ImportRequest(transfer: nil)
                    }
                }
            }
        }
        .navigationTitle("Servidores")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Añadir servidor", systemImage: "plus") { editing = .create }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Escanear QR del Mac", systemImage: "qrcode.viewfinder") {
                    importing = ImportRequest(transfer: nil)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu("Ajustes", systemImage: "gearshape") {
                    Toggle("Sincronizar con iCloud", systemImage: "icloud", isOn: $cloudSyncEnabled)
                    Text("Servidores y huellas, con tu Mac y tus otros dispositivos. Las contraseñas y claves no viajan.")
                    Picker(selection: $agentPermissionMode) {
                        ForEach(ClaudeAgentCommand.PermissionMode.allCases, id: \.self) { mode in
                            Label(mode.title, systemImage: mode.symbolName).tag(mode.rawValue)
                        }
                    } label: {
                        Label("Permisos de los agentes", systemImage: "sparkles")
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .sheet(item: $editing) { mode in
            ServerFormView(mode: mode)
        }
        .sheet(item: $importing) { request in
            ImportServerSheet(transfer: request.transfer)
        }
        // QR escaneado con la cámara del sistema: llega como enlace argos://add-server.
        .onOpenURL { url in
            do {
                importing = ImportRequest(transfer: try ServerTransfer.decode(url.absoluteString))
            } catch {
                linkError = error.userMessage
            }
        }
        .alert(
            "No se pudo añadir el servidor",
            isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
        .confirmationDialog(
            "¿Borrar «\(pendingDeletion?.name ?? "")»?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Borrar servidor", role: .destructive) {
                if let server = pendingDeletion { hub.remove(server) }
                pendingDeletion = nil
            }
        } message: {
            Text("Se borran sus datos de acceso de este dispositivo. Las sesiones y proyectos del servidor no se tocan.")
        }
}

    @ViewBuilder
    private func row(_ server: Server) -> some View {
        if selection != nil {
            ServerRowView(server: server).tag(server.id)
        } else {
            NavigationLink(value: server) { ServerRowView(server: server) }
        }
    }
}

struct ServerRowView: View {
    let server: Server

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.headline)
                Text(verbatim: "\(server.username)@\(server.host)\(server.port == 22 ? "" : ":\(server.port)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if ImportedKeyStore.needsImport(server) {
                    Label("Falta la clave · envíalo desde el Mac", systemImage: "key.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
