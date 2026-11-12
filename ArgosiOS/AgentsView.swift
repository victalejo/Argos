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
    @State private var isShowingLogin = false
    /// Al terminar el login se retoma la creación del agente que lo pidió.
    @State private var launchAfterLogin = false
    /// Sesión de Claude ya confirmada en este servidor: no se vuelve a preguntar.
    @State private var isClaudeConnected = false

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
                        LabeledContent("Permisos") {
                            AgentPermissionPicker(serverID: server.id, workingDirectory: workingDirectory)
                        }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Opciones de agentes", systemImage: "ellipsis.circle") {
                    Button("Conectar Claude…", systemImage: "person.badge.key") {
                        launchAfterLogin = false
                        isShowingLogin = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingLogin) {
            ClaudeLoginSheet(service: service, serverName: server.name, allowsSkip: launchAfterLogin) { connected in
                isShowingLogin = false
                let resume = connected && launchAfterLogin
                launchAfterLogin = false
                if connected { isClaudeConnected = true }
                if resume { launch() }
            }
        }
        .alert("No se pudo crear el agente", isPresented: Binding(get: { errorMessage != nil && agents != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await load()
            if !mine.isEmpty { AgentNotifier.shared.didUseAgents(on: server) }
        }
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
                guard try await isClaudeReady() else {
                    launchAfterLogin = true
                    isShowingLogin = true
                    return
                }
                let session = try await PersistentAgentSession.launch(
                    service: service,
                    workingDirectory: workingDirectory,
                    title: title,
                    permissionMode: AgentPermissionPreferences.effectiveMode(
                        serverID: server.id, workingDirectory: workingDirectory
                    )
                )
                let info = PersistentAgentInfo(id: session.id, isAlive: true, logBytes: 0, meta: session.meta)
                hub.register(session, server: server)
                AgentNotifier.shared.didUseAgents(on: server)
                await load()
                opened = AgentRoute(serverID: server.id, info: info)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    /// `false` si el servidor tiene Claude Code pero sin sesión (y no hay token guardado):
    /// toca el login guiado. Sin Claude instalado sigue adelante y el lanzamiento lo dice.
    private func isClaudeReady() async throws -> Bool {
        if isClaudeConnected || KeychainStore.hasClaudeOAuthToken() { return true }
        guard let status = try await service.claudeAuthStatus() else { return true }
        isClaudeConnected = status.loggedIn
        return status.loggedIn
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
                Text("\(info.meta.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(info.meta.resolvedPermissionMode.title)")
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
