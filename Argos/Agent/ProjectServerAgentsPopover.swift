//
//  ProjectServerAgentsPopover.swift
//  Argos
//
//  «En el servidor»: los agentes persistentes de la carpeta del proyecto, creados aquí, en
//  el iPhone/iPad, Android u otro Mac. Estado (trabajando, espera tu permiso, en reposo,
//  detenido) y última actividad; elegir uno lo abre en una pestaña.
//

import SwiftUI

struct ProjectServerAgentsPopover: View {
    let agents: [PersistentAgentOverview]
    /// Ids de los que ya tienen pestaña.
    let openIDs: Set<String>
    let isRefreshing: Bool
    let onOpen: (PersistentAgentOverview) -> Void
    let onRefresh: () -> Void
    let onShowAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("En el servidor").font(.headline)
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                Button("Recargar", systemImage: "arrow.clockwise", action: onRefresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            if agents.isEmpty {
                Text("No hay agentes persistentes en esta carpeta. Crea uno con «Mantener en el servidor» (junto al +) o desde el iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(agents) { agent in
                            PersistentAgentRow(agent: agent, isOpen: openIDs.contains(agent.id)) { onOpen(agent) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
            Divider()
            Button("Todos los agentes de este servidor…", systemImage: "server.rack", action: onShowAll)
                .buttonStyle(.borderless)
                .padding(12)
        }
        .frame(width: 380)
    }
}

private struct PersistentAgentRow: View {
    let agent: PersistentAgentOverview
    let isOpen: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: agent.activity.systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.meta.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(isOpen ? "Abierta" : agent.activity.title)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(tint)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Abrir en una pestaña (cerrarla no detiene el agente)")
    }

    private var tint: Color {
        switch agent.activity {
        case .working: return .accentColor
        case .waitingPermission: return .orange
        case .idle: return .green
        case .asleep, .stopped: return .secondary
        }
    }

    private var detail: String {
        var parts = [agent.meta.createdAt.formatted(date: .abbreviated, time: .shortened), agent.meta.resolvedPermissionMode.title]
        if let last = agent.lastActivity() {
            parts.append("actividad \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}
