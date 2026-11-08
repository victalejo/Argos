//
//  TerminalWindowBar.swift
//  ArgosiOS
//
//  Pestañas de las ventanas tmux en el iPhone/iPad, como en el Mac: `>_ 1` para las
//  ventanas normales y el icono + nombre del agente (mascota de Claude Code, Codex,
//  Grok) cuando corre uno. El menú «+» abre un terminal o lanza un agente.
//

import SwiftUI

struct TerminalWindowBar: View {
    let windows: [TmuxWindow]
    /// Ventanas en las que los hooks de Claude informan actividad.
    var claudeWindows: Set<Int> = []
    /// Agentes instalados en el servidor (`nil` mientras no se sabe: todos activos).
    var installedAgents: Set<CodingAgent>?
    let onSelect: (TmuxWindow) -> Void
    let onNew: () -> Void
    let onNewAgent: (CodingAgent) -> Void
    let onClose: (TmuxWindow) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let repeated = WindowTabs.repeatedAgents(in: windows, claudeReported: claudeWindows)
                    ForEach(windows) { window in
                        tab(for: window, repeatedAgents: repeated)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            addMenu
                .padding(.trailing, 6)
        }
        .background(Color(white: 0.11))
    }

    // MARK: - Pestaña

    private func tab(for window: TmuxWindow, repeatedAgents: Set<CodingAgent>) -> some View {
        let agent = WindowTabs.agent(for: window, claudeReported: claudeWindows.contains(window.index))
        let title = WindowTabs.title(for: window, agent: agent)
        return Button { onSelect(window) } label: {
            HStack(spacing: 5) {
                if let agent {
                    CodingAgentIcon(agent: agent, size: 11)
                } else {
                    Text(verbatim: ">_")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(window.isActive ? Color.accentColor : .white.opacity(0.55))
                }
                if agent.map(repeatedAgents.contains) ?? true {
                    Text(verbatim: "\(window.index)")
                        .font(.caption.monospaced().weight(.medium))
                }
                if let title {
                    Text(title)
                        .font(.caption.weight(window.isActive ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(window.isActive ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                window.isActive ? Color.white.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(window.isActive ? Color.white.opacity(0.12) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ventana \(window.index): \(title ?? window.name)")
        .accessibilityAddTraits(window.isActive ? .isSelected : [])
        .contextMenu {
            Button("Cerrar ventana", systemImage: "xmark", role: .destructive) { onClose(window) }
                // Cerrar la última ventana mataría la sesión entera.
                .disabled(windows.count <= 1)
        }
    }

    // MARK: - Menú «+»

    private var addMenu: some View {
        Menu {
            Button("Terminal", systemImage: "terminal", action: onNew)
            Section("Iniciar un agente") {
                ForEach(CodingAgent.allCases) { agent in
                    agentItem(agent)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Nueva ventana")
    }

    @ViewBuilder
    private func agentItem(_ agent: CodingAgent) -> some View {
        let installed = installedAgents?.contains(agent) ?? true
        Button { onNewAgent(agent) } label: {
            Label {
                Text(agent.displayName)
                if !installed { Text("no instalado") }
            } icon: {
                Image(uiImage: AgentMenuIcon.image(for: agent))
            }
        }
        .disabled(!installed)
    }
}

/// Iconos de los agentes para los menús de UIKit (que no pintan vistas SwiftUI como la
/// mascota). Se renderizan una vez y se guardan.
@MainActor
enum AgentMenuIcon {
    private static var cache: [CodingAgent: UIImage] = [:]
    private static let renderScale: CGFloat = 3

    static func image(for agent: CodingAgent) -> UIImage {
        if let cached = cache[agent] { return cached }
        let renderer = ImageRenderer(content: CodingAgentIcon(agent: agent, size: 16).padding(1))
        // Fijo: fuera de un contexto de dibujo, el displayScale del trait puede ser 0.
        renderer.scale = renderScale
        guard let rendered = renderer.uiImage else {
            Log.terminal.error("No se pudo dibujar el icono de \(agent.displayName, privacy: .public) para el menú.")
            return UIImage(systemName: agent.symbolName) ?? UIImage()
        }
        let image = rendered.withRenderingMode(.alwaysOriginal)
        cache[agent] = image
        return image
    }
}
