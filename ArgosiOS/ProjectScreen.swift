//
//  ProjectScreen.swift
//  ArgosiOS
//
//  Detalle de un proyecto: Terminal · Archivos · Agentes (como el Mac). Las sesiones
//  sueltas, sin carpeta de proyecto, solo tienen terminal.
//

import SwiftUI

/// Qué se abre en el detalle: la sesión tmux y, si es un proyecto, su carpeta.
struct ProjectTarget: Hashable, Identifiable, Codable {
    let sessionName: String
    let title: String
    let path: String?
    var id: String { sessionName }
}

struct ProjectScreen: View {
    let server: Server
    let target: ProjectTarget

    /// Pestaña del detalle; vive en `AppNavigation` para sobrevivir a giros y arranques.
    @Binding var mode: DetailMode
    @Environment(ServerHub.self) private var hub
    @State private var showPorts = false
    @State private var showTasks = false

    private var service: any SSHServicing { hub.viewModel(for: server).service }

    var body: some View {
        content
            .toolbar {
                if target.path != nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Vista", selection: $mode) {
                            Image(systemName: "terminal").tag(DetailMode.terminal)
                                .accessibilityLabel("Terminal")
                            Image(systemName: "folder").tag(DetailMode.files)
                                .accessibilityLabel("Archivos")
                            Image(systemName: "arrow.triangle.branch").tag(DetailMode.changes)
                                .accessibilityLabel("Cambios")
                            Image(systemName: "sparkles").tag(DetailMode.agent)
                                .accessibilityLabel("Agentes")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }
                }
                if project != nil {
                    ToolbarItem(placement: .topBarTrailing) { tasksButton }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPorts = true } label: {
                        Image(systemName: "network")
                    }
                    .accessibilityLabel("Puertos")
                }
            }
            .sheet(isPresented: $showPorts) {
                PortForwardsSheet(service: service, serverName: server.name)
            }
            .sheet(isPresented: $showTasks) {
                if let project {
                    ClaudeTasksScreen(project: project, viewModel: hub.viewModel(for: server))
                }
            }
            .portForwardRequests(service: service, serverName: server.name)
            // Al abrir la sesión sus avisos ya entregados sobran.
            .onAppear { AgentNotifier.shared.withdrawDelivered(serverID: server.id, session: target.sessionName) }
    }

    /// El proyecto de Argos de esta sesión (las sesiones sueltas no tienen cola).
    private var project: Project? {
        hub.viewModel(for: server).project(forSession: target.sessionName)
    }

    private var tasksButton: some View {
        Button { showTasks = true } label: {
            Image(systemName: "list.bullet.clipboard")
        }
        .accessibilityLabel("Encargos")
    }

    @ViewBuilder
    private var content: some View {
        switch (mode, target.path) {
        case (.files, let path?):
            RemoteFilesView(service: service, root: path, path: path)
        case (.changes, let path?):
            GitChangesView(viewModel: hub.viewModel(for: server), path: path)
        case (.agent, let path?):
            AgentsView(server: server, workingDirectory: path, title: target.title)
        default:
            TerminalScreen(server: server, sessionName: target.sessionName, projectPath: target.path)
        }
    }
}
