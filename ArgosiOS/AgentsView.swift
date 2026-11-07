//
//  AgentsView.swift
//  ArgosiOS
//
//  Agentes de Claude Code PERSISTENTES de un proyecto (ver `PersistentAgentScript`):
//  corren en el servidor aunque el iPhone se bloquee o se cierre la app. Aquí se
//  listan, se crean y se abren para conversar.
//

import SwiftUI

struct AgentsView: View {
    let server: Server
    let workingDirectory: String
    let title: String

    @Environment(ServerHub.self) private var hub
    @State private var agents: [PersistentAgentInfo]?
    @State private var errorMessage: String?
    @State private var isLaunching = false
    @State private var opened: AgentRoute?

    private var service: any SSHServicing { hub.viewModel(for: server).service }

    /// Agentes de ESTE proyecto (misma carpeta).
    private var mine: [PersistentAgentInfo] {
        (agents ?? []).filter { $0.meta.workingDirectory == workingDirectory }
    }

    var body: some View {
        Group {
            if let errorMessage, agents == nil {
                ContentUnavailableView {
                    Label("No se pudieron leer los agentes", systemImage: "sparkles")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Reintentar") { Task { await load() } }
                }
            } else if agents == nil {
                ProgressView()
            } else {
                List {
                    Section {
                        Button(action: launch) {
                            HStack {
                                Label("Nuevo agente", systemImage: "plus.bubble")
                                Spacer()
                                if isLaunching { ProgressView() }
                            }
                        }
                        .disabled(isLaunching)
                    } footer: {
                        Text("El agente trabaja en el servidor: puedes bloquear el iPhone o cerrar Argos y volver luego a ver qué hizo.")
                    }
                    if !mine.isEmpty {
                        Section("Conversaciones") {
                            ForEach(mine) { info in
                                Button {
                                    opened = AgentRoute(serverID: server.id, info: info)
                                } label: {
                                    AgentRowView(info: info)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Agentes")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { route in
            AgentChatView(session: hub.agentSession(for: route.info, server: server))
        }
        .alert("No se pudo crear el agente", isPresented: Binding(get: { errorMessage != nil && agents != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            agents = try await PersistentAgentSession.list(service: service)
            errorMessage = nil
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func launch() {
        isLaunching = true
        Task {
            defer { isLaunching = false }
            do {
                let session = try await PersistentAgentSession.launch(
                    service: service, workingDirectory: workingDirectory, title: title
                )
                let info = PersistentAgentInfo(id: session.id, isAlive: true, logBytes: 0, meta: session.meta)
                hub.register(session, server: server)
                await load()
                opened = AgentRoute(serverID: server.id, info: info)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

/// Destino de navegación hacia una conversación con un agente.
struct AgentRoute: Hashable, Identifiable {
    let serverID: Server.ID
    let info: PersistentAgentInfo
    var id: String { info.id }

    static func == (lhs: AgentRoute, rhs: AgentRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct AgentRowView: View {
    let info: PersistentAgentInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(info.isAlive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.meta.title).font(.body.weight(.medium))
                Text(info.meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(info.isAlive ? "En marcha" : "Detenido")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((info.isAlive ? Color.green : Color.gray).opacity(0.15), in: Capsule())
                .foregroundStyle(info.isAlive ? .green : .secondary)
        }
    }
}
