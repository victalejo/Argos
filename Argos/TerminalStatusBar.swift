//
//  TerminalStatusBar.swift
//  Argos
//
//  Barra inferior del terminal: servidor · rama git · agentes activos · estado · atajos.
//

import SwiftUI

struct TerminalStatusBar: View {
    let serverName: String
    let gitBranch: String?
    let workingPath: String?
    let agentCount: Int
    let isConnected: Bool
    let statusText: String

    var body: some View {
        HStack(spacing: 12) {
            if !serverName.isEmpty {
                Label(serverName, systemImage: "desktopcomputer")
                    .lineLimit(1)
            }
            if let gitBranch {
                Label(gitBranch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Rama git de \(workingPath ?? "la carpeta")")
            }
            if agentCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Color.teal).frame(width: 6, height: 6)
                    Text("\(agentCount) \(agentCount == 1 ? "agente" : "agentes")")
                }
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(isConnected ? Color.teal : Color.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(statusText)
            }
            Spacer(minLength: 8)
            Text("⌘K comandos · ⌘T nueva · ⌘W cerrar")
                .font(.caption2)
                .lineLimit(1)
        }
        .font(.caption)
        .labelStyle(CompactStatusLabelStyle())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Etiqueta compacta (icono pequeño pegado al texto) para la barra inferior.
private struct CompactStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
