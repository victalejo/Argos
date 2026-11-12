//
//  ProjectScreen.swift
//  ArgosiOS
//
//  Detalle de un proyecto: Terminal · Archivos · Agentes (como el Mac). Las sesiones
//  sueltas, sin carpeta de proyecto, solo tienen terminal.
//

import SwiftUI

/// Qué se abre en el detalle: la sesión tmux y, si es un proyecto, su carpeta.
struct ProjectTarget: Hashable, Identifiable {
    let sessionName: String
    let title: String
    let path: String?
    var id: String { sessionName }
}

struct ProjectScreen: View {
    let server: Server
    let target: ProjectTarget

    @Environment(ServerHub.self) private var hub
    @State private var mode: DetailMode = .terminal
    @State private var showPorts = false

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
            .portForwardRequests(service: service, serverName: server.name)
            .onAppear { hub.viewing = handle }
            .onDisappear { if hub.viewing == handle { hub.viewing = nil } }
    }

    private var handle: SessionHandle { SessionHandle(serverID: server.id, sessionID: target.sessionName) }

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
