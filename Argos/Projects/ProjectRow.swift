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
    /// Envío al Mac / al servidor en curso o recién terminado (abre su hoja al pulsar).
    var sync: ProjectSyncJob?
    var onOpenSync: () -> Void = {}

    private var isRunning: Bool { connection != nil }
    private var isOpenHere: Bool { connection == .live || connection == .connecting }
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isRunning ? "folder.fill" : "folder")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOpenHere ? Color.accentColor : isRunning ? .primary : .secondary)
                .frame(width: 34, height: 34)
                .background(isOpenHere ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isRunning ? .primary : .secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let sync {
                ProjectSyncBadge(job: sync, action: onOpenSync)
            }
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
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .background(isHovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
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

/// Progreso del envío del proyecto en su fila: anillo mientras copia, check o aviso
/// al terminar. Pulsarlo reabre la hoja del envío.
private struct ProjectSyncBadge: View {
    let job: ProjectSyncJob
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon.frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    @ViewBuilder
    private var icon: some View {
        switch job.phase {
        case .running:
            ProgressView(value: job.engine.fraction)
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
        default:
            Image(systemName: job.isToMac ? "laptopcomputer.and.arrow.down" : "icloud.and.arrow.up")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var helpText: String {
        let destination = job.isToMac ? "al Mac" : "al servidor"
        switch job.phase {
        case .running:
            return "Enviando \(destination): \(job.engine.doneFiles) de \(job.engine.totalFiles) archivos. Clic para ver."
        case .done:
            return "Envío \(destination) terminado. Clic para ver."
        case .failed:
            return "El envío \(destination) falló. Clic para ver."
        default:
            return "Envío \(destination) pendiente. Clic para ver."
        }
    }
}
