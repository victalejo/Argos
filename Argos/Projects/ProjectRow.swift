//
//  ProjectRow.swift
//  Argos
//
//  Fila de un proyecto en la barra lateral: carpeta, estado (en marcha con su
//  conexión, o detenido) y el aviso de Claude Code.
//

import SwiftUI

struct ProjectRow: View {
    let entry: ProjectEntry
    /// Estado de conexión del terminal si el proyecto corre; `nil` = detenido.
    let connection: SessionConnectionState?
    var claude: ClaudeActivity?

    private var isRunning: Bool { connection != nil }
    private var isOpenHere: Bool { connection == .live || connection == .connecting }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isRunning ? "folder.fill" : "folder")
                .font(.body)
                .foregroundStyle(isOpenHere ? Color.accentColor : isRunning ? .primary : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.project.name)
                    .font(.headline)
                    .foregroundStyle(isRunning ? .primary : .secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let checkout = entry.project.macCheckout {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                    .help("En el Mac «\(checkout.macName)» desde \(checkout.date.formatted(.relative(presentation: .named)))")
            }
            if let claude {
                ClaudeActivityBadge(activity: claude)
            }
            if let connection {
                ConnectionIndicator(state: connection)
            } else {
                Image(systemName: "stop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .help("Detenido: no consume recursos en el servidor")
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var subtitle: String {
        let folder = Self.shortPath(entry.project.path)
        if let checkout = entry.project.macCheckout, entry.session == nil {
            return "En el Mac «\(checkout.macName)»"
        }
        guard let session = entry.session else { return "Detenido · \(folder)" }
        let windows = "\(session.windowCount) \(session.windowCount == 1 ? "ventana" : "ventanas")"
        return "\(windows) · \(folder)"
    }

    private var accessibilityText: String {
        let state = connection?.label ?? "Detenido"
        let claudeText = claude.map { ", \($0.label)" } ?? ""
        return "Proyecto \(entry.project.name), \(state)\(claudeText), carpeta \(entry.project.path)"
    }

    /// Últimos dos componentes de la ruta ("…/Desarrollo/coro") para que quepa.
    static func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 2 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}
