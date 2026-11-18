//
//  ProjectDetailView.swift
//  Argos
//
//  Columna 3 de un proyecto o sesión: cabecera (nombre, servidor, modo y «Puertos») y el
//  panel del modo elegido (Terminal · Archivos · Cambios · Agente). Los paneles abiertos
//  se conservan al cambiar de modo (`DetailPanelStack`).
//

import SwiftUI

struct ProjectDetailView: View {
    @Bindable var model: ArgosAppModel
    let handle: SessionHandle
    let vm: SessionsViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: TmuxSession? { vm.session(withID: handle.sessionID) }
    private var project: Project? { vm.project(forSession: handle.sessionID) }
    private var serverName: String { model.store.server(withID: handle.serverID)?.name ?? "el servidor" }
    private var mode: DetailMode { model.detailModes[handle] ?? .terminal }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DetailPanelStack(mode: mode) { panel($0) }
                .id(handle)
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity
                Spacer(minLength: 12)
                modeControl
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                modeControl
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            WorkspaceIcon(symbol: project == nil ? "terminal" : "folder.fill", size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(project?.name ?? handle.sessionID)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(project?.name ?? handle.sessionID)
                Label(model.store.server(withID: handle.serverID)?.name ?? "Servidor", systemImage: "server.rack")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Selector de modo + botón «Puertos» (reenvío de puertos del servidor).
    private var modeControl: some View {
        HStack(spacing: 10) {
            Picker("Modo de trabajo", selection: modeBinding) {
                Label("Terminal", systemImage: "terminal").tag(DetailMode.terminal)
                Label("Archivos", systemImage: "folder").tag(DetailMode.files)
                Label("Cambios", systemImage: "arrow.triangle.branch").tag(DetailMode.changes)
                Label("Agente", systemImage: "sparkles").tag(DetailMode.agent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.large)
            .help("Elige cómo trabajar en este proyecto")
            PortForwardsButton(service: vm.service, serverName: serverName)
                .id(handle.serverID)
        }
    }

    private var modeBinding: Binding<DetailMode> {
        Binding(
            get: { model.detailModes[handle] ?? .terminal },
            set: { mode in
                withAnimation(ArgosTheme.motion(reduceMotion: reduceMotion)) {
                    model.detailModes[handle] = mode
                }
            }
        )
    }

    // MARK: - Paneles

    @ViewBuilder
    private func panel(_ mode: DetailMode) -> some View {
        switch mode {
        case .terminal:
            if let session {
                SessionTerminalView(
                    handle: handle,
                    session: session,
                    service: vm.service,
                    store: model.terminalStore,
                    claudeByWindow: vm.claudeActivity.windows(forSession: session.name),
                    projectPath: project?.path,
                    serverName: model.store.server(withID: handle.serverID)?.name ?? "",
                    onEnded: { Task { await vm.refreshSessionsQuietly() } }
                )
                .id(handle)
            } else if let project {
                // Proyecto detenido: al abrirlo aparece su sesión y esta rama cede al terminal.
                ProjectStoppedView(project: project, vm: vm)
                    .id(project.id)
            }
        case .files:
            if let project {
                FilesPanelView(root: project.path, service: vm.service)
                    .id(handle)
            } else {
                LooseSessionFilesView(sessionName: handle.sessionID, service: vm.service)
                    .id(handle)
            }
        case .changes:
            if let project {
                GitChangesPanelView(path: project.path, viewModel: vm)
                    .id(handle)
            } else {
                LooseSessionRootView(sessionName: handle.sessionID, service: vm.service) { root in
                    GitChangesPanelView(path: root, viewModel: vm)
                }
                .id(handle)
            }
        case .agent:
            AgentPanelView(
                handle: handle,
                service: vm.service,
                store: model.agentStore,
                title: project?.name ?? handle.sessionID,
                serverName: serverName,
                projectPath: project?.path
            )
            .id(handle)
        }
    }
}
