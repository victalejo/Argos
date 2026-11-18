//
//  ServersView.swift
//  ArgosiOS
//
//  Pantalla inicial: servidores | proyectos | terminal/archivos/agentes. Un único
//  `NavigationSplitView` para iPhone e iPad: en ancho compacto se colapsa en una pila
//  (servidores → proyectos → detalle), así que girar o redimensionar no reconstruye la
//  navegación. La selección vive en `AppNavigation` y se restaura con `@SceneStorage`.
//  Deslizar un servidor permite editarlo o borrarlo; mantenerlo pulsado, además, ver sus
//  recursos, activar el indicador de Claude, pasar a una clave del iPhone u olvidar su
//  host key (`ServerActions`).
//

import CoreSpotlight
import SwiftUI

/// Alta desde el QR del Mac (con el código ya leído si llegó por enlace).
struct ImportRequest: Identifiable {
    let id = UUID()
    let transfer: ServerTransfer?
}

struct RootView: View {
    /// Argumento de lanzamiento de los tests de interfaz: arranca sin la navegación
    /// restaurada de una ejecución anterior (`@SceneStorage` sobrevive entre lanzamientos
    /// en el mismo simulador).
    static let resetStateArgument = "-ArgosResetNavigation"
    /// Tests de interfaz: `-ArgosOpenURL <enlace>` entrega el enlace al arrancar por el
    /// mismo camino que `onOpenURL`. Algunos simuladores de la CI (iOS 18.5 recién
    /// arrancado) no entregan `XCUIApplication.open(_:)`: mandan la app a segundo plano y
    /// SpringBoard se queda en la pantalla de inicio.
    static let openURLArgument = "-ArgosOpenURL"

    @Environment(ServerHub.self) private var hub
    @SceneStorage("argos.navigation") private var savedNavigation = ""
    @State private var navigation = AppNavigation()
    @State private var restored = false
    /// Enlace `argos://add-server` recibido (QR escaneado con la cámara del sistema).
    /// Vive en la raíz de la escena: la columna de servidores puede no estar montada
    /// (iPhone con otra columna visible o con la navegación restaurada).
    @State private var linkImport: ImportRequest?
    @State private var linkError: String?
    @Environment(AppLock.self) private var lock
    /// Enlace recibido con la app bloqueada: se atiende al desbloquear.
    @State private var deferredLink: URL?

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
                ), mode: $navigation.mode)
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
        .onOpenURL(perform: handleLink)
        // Proyecto tocado en Spotlight: mismo camino que un aviso (respeta Face ID).
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let route = ProjectShortcutIndex.route(forSpotlightIdentifier: id) else { return }
            hub.follow(route)
        }
        .onChange(of: lock.isLocked) { _, locked in
            guard !locked, let url = deferredLink else { return }
            deferredLink = nil
            handleLink(url)
        }
        .sheet(item: $linkImport) { request in
            ImportServerSheet(transfer: request.transfer)
        }
        .alert(
            "No se pudo añadir el servidor",
            isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
    }

    /// Un enlace nuevo no sustituye una confirmación ya abierta (se podría cambiar el
    /// servidor que el usuario está revisando sin que lo note).
    private func handleLink(_ url: URL) {
        if let deferred = AppLockPolicy.deferring(url, enabled: lock.isEnabled, isLocked: lock.isLocked) {
            deferredLink = deferred
            return
        }
        guard linkImport == nil else {
            Log.store.notice("Se ignora un enlace de alta: ya hay una confirmación abierta")
            return
        }
        do {
            linkImport = ImportRequest(transfer: try ServerTransfer.decode(url.absoluteString))
        } catch {
            linkError = error.userMessage
        }
    }

    /// Arranque en frío o escena nueva: vuelve a donde se estaba.
    private func restoreOnce() {
        guard !restored else { return }
        restored = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(Self.resetStateArgument) { savedNavigation = "" }
        navigation.restore(from: savedNavigation)
        if let index = arguments.firstIndex(of: Self.openURLArgument), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            handleLink(url)
        }
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
    @State private var serverAction: ServerAction?
    @State private var showingSettings = false
    /// Alta escaneando el QR del Mac con la cámara de la app (el enlace del QR leído con
    /// la cámara del sistema lo atiende `RootView`).
    @State private var importing: ImportRequest?

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
                    ServerActionItems(server: server) { serverAction = $0 }
                    Divider()
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
                Button("Ajustes", systemImage: "gearshape") { showingSettings = true }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .serverActions($serverAction)
        .sheet(item: $editing) { mode in
            ServerFormView(mode: mode)
        }
        .sheet(item: $importing) { request in
            ImportServerSheet(transfer: request.transfer)
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
            Text("Se borran sus datos de acceso y su huella de host key de este dispositivo. Las sesiones y proyectos del servidor no se tocan.")
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
                    Label("Falta la clave en este dispositivo", systemImage: "key.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
