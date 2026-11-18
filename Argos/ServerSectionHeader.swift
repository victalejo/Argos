//
//  ServerSectionHeader.swift
//  Argos
//
//  Encabezado de la sección de un servidor en la columna central: plegar/desplegar,
//  resumen con el servidor plegado y menú de acciones de proyectos.
//

import SwiftUI

struct ServerSectionHeader: View {
    let server: Server
    let vm: SessionsViewModel?
    let terminalStore: TerminalSessionStore
    let onNewProject: () -> Void
    let onImport: () -> Void
    let onStopBackground: ([Project]) -> Void

    @State private var collapsedGroups = CollapsedSessionGroups.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isCollapsed = collapsedGroups.isServerCollapsed(server.id)
        HStack(spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    collapsedGroups.toggleServer(server.id)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Image(systemName: "server.rack")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(server.name)
                        .font(.system(size: 12, weight: .semibold))
                        .textCase(nil)
                        .foregroundStyle(.primary)
                    if isCollapsed, let vm, case .loaded = vm.state {
                        collapsedSummary(vm)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expandir \(server.name)" : "Colapsar \(server.name)")
            .accessibilityLabel("Servidor \(server.name)")
            .accessibilityValue(isCollapsed ? "colapsado" : "expandido")
            if let vm, vm.isWorking {
                ProgressView().controlSize(.mini)
            }
            if let vm, case .loaded = vm.state {
                serverMenu(vm)
            }
        }
        .padding(.vertical, 5)
    }

    /// Con el servidor plegado: cuántos proyectos oculta y el aviso de Claude más urgente.
    @ViewBuilder
    private func collapsedSummary(_ vm: SessionsViewModel) -> some View {
        let listing = vm.projectListing
        Text("\(listing.entries.count + listing.looseSessions.count)")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.09), in: Capsule())
        if let claude = vm.claudeActivity.activity(forSessions: vm.sessions.map(\.name)) {
            ClaudeActivityBadge(activity: claude, size: 10)
        }
    }

    /// Acciones de proyectos del servidor (crear, importar, liberar memoria).
    private func serverMenu(_ vm: SessionsViewModel) -> some View {
        let background = backgroundProjects(vm)
        return Menu {
            Button("Nuevo proyecto…", action: onNewProject)
            Button("Importar sesiones como proyectos…", action: onImport)
                .disabled(vm.projectListing.looseSessions.isEmpty)
            Divider()
            Button("Detener proyectos en segundo plano (\(background.count))…") { onStopBackground(background) }
                .disabled(background.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Acciones de proyectos en \(server.name)")
    }

    /// Proyectos que corren sin estar abiertos en ningún terminal (ni de Argos ni de
    /// otro cliente): siguen consumiendo memoria sin que nadie los mire.
    private func backgroundProjects(_ vm: SessionsViewModel) -> [Project] {
        vm.projectListing.entries.compactMap { entry in
            guard let session = entry.session else { return nil }
            let handle = SessionHandle(serverID: server.id, sessionID: session.name)
            let state = terminalStore.connectionState(for: handle, isAttached: session.isAttached)
            return state == .dormant ? entry.project : nil
        }
    }
}
