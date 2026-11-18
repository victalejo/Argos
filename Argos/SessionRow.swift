//
//  SessionRow.swift
//  Argos
//
//  Fila de una sesión tmux suelta en la columna central y su indicador de conexión.
//

import SwiftUI

// MARK: - Modelo auxiliar para acciones con contexto de servidor

struct SessionAction: Identifiable {
    let server: Server
    let session: TmuxSession
    var id: String { "\(server.id)-\(session.id)" }
}

// MARK: - Fila de sesión

extension SessionConnectionState {
    /// Color del indicador. (`connecting` usa spinner y `dormant` usa luna en su lugar.)
    var color: Color {
        switch self {
        case .live: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .attachedElsewhere: return .blue
        case .dormant: return .secondary.opacity(0.4)
        }
    }

    /// Texto del tooltip.
    var label: String {
        switch self {
        case .live: return String(localized: "Activa (cargada y conectada)")
        case .connecting: return String(localized: "Conectando…")
        case .error: return String(localized: "Error de conexión")
        case .attachedElsewhere: return String(localized: "Adjunta por otro cliente")
        case .dormant: return String(localized: "Dormida (no cargada)")
        }
    }
}

struct SessionRow: View {
    let session: TmuxSession
    var state: SessionConnectionState = .dormant
    var displayName: String? = nil
    /// Estado de Claude Code en la sesión (si tiene los hooks de Argos).
    var claude: ClaudeActivity? = nil

    private var title: String { displayName ?? session.name }
    private var isLoaded: Bool { state == .live || state == .connecting }
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLoaded ? "terminal.fill" : "terminal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isLoaded ? Color.accentColor : .secondary)
                .frame(width: 34, height: 34)
                .background(isLoaded ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let claude {
                ClaudeActivityBadge(activity: claude)
            }

            ConnectionIndicator(state: state)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .background(isHovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Etiqueta de VoiceOver: nombre + estado de conexión + nº de ventanas en una sola
    /// frase (la fila se expone como un único elemento, no como piezas sueltas).
    private var accessibilityText: String {
        let windows = String(localized: "\(session.windowCount) ventanas")
        let claudeText = claude.map { ", \($0.label)" } ?? ""
        return "\(title), \(state.label), \(windows)\(claudeText)"
    }

    private var subtitle: String {
        let windows = String(localized: "\(session.windowCount) ventanas")
        let age = session.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(windows) · \(age)"
    }
}

/// Indicador del estado de conexión de una sesión. Cada estado usa una FORMA distinta
/// además del color, para que sea distinguible sin depender del color (daltonismo):
/// viva = punto, error = exclamación, adjunta-por-otro = persona, conectando = spinner,
/// dormida = luna.
struct ConnectionIndicator: View {
    let state: SessionConnectionState

    var body: some View {
        Group {
            switch state {
            case .connecting:
                ProgressView().controlSize(.mini)
            case .dormant:
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.7))
            case .live:
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(state.color)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(state.color)
            case .attachedElsewhere:
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(state.color)
            }
        }
        .frame(width: 14, height: 14)
        .help(state.label)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Fila de sesión") {
    List(TmuxSession.samples) { SessionRow(session: $0) }
        .frame(width: 320, height: 320)
}
#endif
