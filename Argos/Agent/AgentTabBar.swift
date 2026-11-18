//
//  AgentTabBar.swift
//  Argos
//
//  Barra de pestañas del panel Agente: conversaciones de esta sesión y agentes
//  persistentes del servidor (con su icono de servidor). Cerrar la pestaña de un
//  persistente solo deja de mirarlo: el agente sigue en el servidor.
//

import SwiftUI

struct AgentTabBar: View {
    let slots: [AgentTabSlot]
    let selectedID: UUID?
    let isAdding: Bool
    let placement: AgentConversationPlacement
    /// Agentes persistentes de la carpeta (para el botón «En el servidor»).
    let serverAgentCount: Int
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: (AgentConversationPlacement) -> Void
    let onShowServerAgents: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(slots) { slot in
                        AgentTabChip(
                            slot: slot,
                            isSelected: slot.id == selectedID,
                            onSelect: { onSelect(slot.id) },
                            onClose: { onClose(slot.id) }
                        )
                    }
                    newButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            serverAgentsButton
        }
        .background(.bar)
    }

    private var newButton: some View {
        HStack(spacing: 2) {
            Button { onNew(placement) } label: {
                if isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .disabled(isAdding)
            .accessibilityLabel("Nueva conversación (\(placement.title))")
            .help("Nueva conversación · \(placement.title) (⌘T)")
            Menu {
                ForEach(AgentConversationPlacement.allCases, id: \.self) { option in
                    Button {
                        onNew(option)
                    } label: {
                        Label("Nueva: \(option.title)", systemImage: option.systemImage)
                    }
                    .help(option.detail)
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isAdding)
            .accessibilityLabel("Elegir dónde vive la conversación nueva")
            .help("Elegir: solo en esta sesión o mantener en el servidor (se recuerda en este proyecto)")
        }
    }

    private var serverAgentsButton: some View {
        Button(action: onShowServerAgents) {
            Label(serverAgentCount > 0 ? "En el servidor (\(serverAgentCount))" : "En el servidor", systemImage: "server.rack")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .help("Agentes que siguen en el servidor en esta carpeta (también los del iPhone o Android)")
    }
}

private struct AgentTabChip: View {
    let slot: AgentTabSlot
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPersistent: Bool { slot.lifecycle == .persistent }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) { label }
                .buttonStyle(.plain)
                .help(helpText)
                .accessibilityLabel("Conversación: \(slot.title), \(slot.permissionMode.title)\(isPersistent ? ", en el servidor" : "")")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            closeButton
        }
        .padding(.horizontal, 10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(isHovering ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.05)))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
    }

    private var label: some View {
        HStack(spacing: 7) {
            AgentStatusDot(phase: slot.conversation.phase)
            if isPersistent {
                Image(systemName: "server.rack").font(.caption2).foregroundStyle(.tint)
            }
            Image(systemName: slot.permissionMode.symbolName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(slot.title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 180)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHovering || isSelected ? 1 : 0.4)
        .help(isPersistent ? "Cerrar pestaña (el agente sigue en el servidor)" : "Cerrar conversación (detiene su Claude en el servidor)")
        .accessibilityLabel("Cerrar \(slot.title)")
    }

    private var helpText: String {
        let mode = "Permisos: \(slot.permissionMode.title)"
        return isPersistent ? "Agente en el servidor (sigue aunque cierres Argos). \(mode)" : "Solo en esta sesión. \(mode)"
    }
}

/// Punto de estado de una conversación.
struct AgentStatusDot: View {
    let phase: AgentConversationPhase

    var body: some View {
        switch phase {
        case .awaitingPermission:
            Image(systemName: "bell.badge.fill").font(.system(size: 9)).foregroundStyle(.orange)
        case .working, .resuming:
            ProgressView().controlSize(.mini)
        case .stopped(let reason):
            Image(systemName: reason == .ended ? "stop.circle" : "exclamationmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(reason == .ended ? Color.secondary : Color.red)
        case .asleep:
            Image(systemName: "moon.zzz").font(.system(size: 9)).foregroundStyle(.secondary)
        case .ready:
            Circle().fill(.green).frame(width: 6, height: 6)
        }
    }
}
