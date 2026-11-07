//
//  ServersView.swift
//  ArgosiOS
//
//  Pantalla inicial: lista de servidores. Tocar uno abre sus proyectos; deslizar
//  permite editarlo o borrarlo.
//

import SwiftUI

struct ServersView: View {
    @Environment(ServerHub.self) private var hub
    @State private var editing: ServerFormView.Mode?
    @State private var pendingDeletion: Server?

    var body: some View {
        NavigationStack {
            List {
                ForEach(hub.store.servers) { server in
                    NavigationLink(value: server) {
                        ServerRowView(server: server)
                    }
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
                    }
                }
            }
            .navigationTitle("Servidores")
            .navigationDestination(for: Server.self) { server in
                ProjectsView(server: server)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Añadir servidor", systemImage: "plus") { editing = .create }
                }
            }
            .sheet(item: $editing) { mode in
                ServerFormView(mode: mode)
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
            }
        }
        .padding(.vertical, 2)
    }
}
