//
//  TerminalWindowBar.swift
//  ArgosiOS
//
//  Pestañas de las ventanas tmux en el iPhone/iPad, como en el Mac: `>_ 1` para las
//  ventanas normales y el icono + nombre del agente (mascota de Claude Code, Codex,
//  Grok) cuando corre uno, con la insignia de actividad de Claude (trabajando, espera,
//  terminó) y el color de la ventana. El menú «+» abre un terminal o lanza un agente;
//  mantener pulsada una pestaña la renombra, le pone color o la cierra.
//

import SwiftUI

struct TerminalWindowBar: View {
    let windows: [TmuxWindow]
    /// Estado de Claude por ventana (lo informan los hooks de Argos).
    var claudeActivity: [Int: ClaudeActivity] = [:]
    /// Agentes instalados en el servidor (`nil` mientras no se sabe: todos activos).
    var installedAgents: Set<CodingAgent>?
    let onSelect: (TmuxWindow) -> Void
    let onNew: () -> Void
    let onNewAgent: (CodingAgent) -> Void
    let onClose: (TmuxWindow) -> Void
    var onRename: (TmuxWindow) -> Void = { _ in }
    var onColor: (TmuxWindow, WindowColor?) -> Void = { _, _ in }

    private var claudeWindows: Set<Int> { Set(claudeActivity.keys) }

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

    // En piezas pequeñas y con tipos explícitos: en una sola expresión, el compilador de
    // la CI (Swift 6.1) tardaba demasiado en comprobarla.
    private func tab(for window: TmuxWindow, repeatedAgents: Set<CodingAgent>) -> some View {
        let agent: CodingAgent? = WindowTabs.agent(for: window, claudeReported: claudeWindows.contains(window.index))
        let title: String? = WindowTabs.title(for: window, agent: agent)
        let showsIndex: Bool = agent.map { (agent: CodingAgent) -> Bool in repeatedAgents.contains(agent) } ?? true
        return Button { onSelect(window) } label: {
            tabChrome(window, tabLabel(window, agent: agent, title: title, showsIndex: showsIndex))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(window, title: title))
        .accessibilityAddTraits(window.isActive ? .isSelected : [])
        .contextMenu { tabMenu(window) }
    }

    /// Icono (agente o `>_`), número, título e insignia de Claude.
    private func tabLabel(_ window: TmuxWindow, agent: CodingAgent?, title: String?, showsIndex: Bool) -> some View {
        HStack(spacing: 5) {
            tabIcon(window, agent: agent)
            if showsIndex {
                Text(verbatim: "\(window.index)")
                    .font(.caption.monospaced().weight(.medium))
            }
            if let title {
                Text(title)
                    .font(.caption.weight(window.isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            if let activity = claudeActivity[window.index] {
                ClaudeActivityBadge(activity: activity, size: 10)
            }
        }
    }

    @ViewBuilder
    private func tabIcon(_ window: TmuxWindow, agent: CodingAgent?) -> some View {
        if let agent {
            CodingAgentIcon(agent: agent, size: 11)
        } else {
            let tint: Color = window.isActive ? Color.accentColor : Color.white.opacity(0.55)
            Text(verbatim: ">_")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
        }
    }

    /// Fondo, borde y franja de color de la pestaña.
    private func tabChrome<Content: View>(_ window: TmuxWindow, _ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let foreground: Color = window.isActive ? Color.white : Color.white.opacity(0.6)
        let fill: Color = window.isActive ? Color.white.opacity(0.14) : Color.clear
        let border: Color = window.isActive ? Color.white.opacity(0.12) : Color.clear
        return content
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .overlay(alignment: .bottom) { colorStripe(window) }
            .contentShape(shape)
    }

    @ViewBuilder
    private func colorStripe(_ window: TmuxWindow) -> some View {
        if let color = window.color {
            Capsule().fill(color.swatch).frame(height: 2.5).padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func tabMenu(_ window: TmuxWindow) -> some View {
        Button("Renombrar…", systemImage: "pencil") { onRename(window) }
        Menu("Color", systemImage: "paintpalette") { colorItems(window) }
        Divider()
        Button("Cerrar ventana", systemImage: "xmark", role: .destructive) { onClose(window) }
            // Cerrar la última ventana mataría la sesión entera.
            .disabled(windows.count <= 1)
    }

    @ViewBuilder
    private func colorItems(_ window: TmuxWindow) -> some View {
        Button("Sin color", systemImage: window.color == nil ? "checkmark" : "circle.slash") { onColor(window, nil) }
        ForEach(WindowColor.allCases) { (color: WindowColor) in
            Button { onColor(window, color) } label: {
                Label { Text(color.displayName) } icon: { Image(uiImage: color.menuSwatch(selected: window.color == color)) }
            }
        }
    }

    private func accessibilityLabel(_ window: TmuxWindow, title: String?) -> String {
        var parts = ["Ventana \(window.index): \(title ?? window.name)"]
        if let activity = claudeActivity[window.index] { parts.append(activity.label) }
        if let color = window.color { parts.append("color \(color.displayName.lowercased())") }
        return parts.joined(separator: ", ")
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

extension WindowColor {
    /// Color de SwiftUI con el que se pinta la pestaña.
    var swatch: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    /// Círculo de color para los menús de UIKit (los SF Symbols se pintan monocromos).
    @MainActor
    func menuSwatch(selected: Bool) -> UIImage {
        let size = CGSize(width: 16, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(swatch).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
            if selected {
                UIColor.white.setStroke()
                context.cgContext.setLineWidth(1.5)
                context.cgContext.strokeEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5))
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
