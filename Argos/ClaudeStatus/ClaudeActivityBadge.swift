//
//  ClaudeActivityBadge.swift
//  Argos
//
//  Indicador visual del estado de Claude Code (fila de sesión y pestaña de ventana).
//  Forma + color distintos por estado (distinguible sin depender del color).
//

import SwiftUI

struct ClaudeActivityBadge: View {
    let activity: ClaudeActivity
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch activity {
            case .waiting:
                Image(systemName: "bell.badge.fill")
                    .symbolEffect(.pulse, options: .repeating)
            case .done:
                Image(systemName: "checkmark.circle.fill")
            case .working:
                Image(systemName: "ellipsis.circle.fill")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
        .font(.system(size: size))
        .foregroundStyle(activity.tint)
        .help(activity.label)
        .accessibilityLabel(activity.label)
    }
}

extension ClaudeActivity {
    var tint: Color {
        switch self {
        case .waiting: return .orange
        case .done: return .green
        case .working: return .blue
        }
    }
}
