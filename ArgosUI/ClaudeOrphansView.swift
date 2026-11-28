//
//  ClaudeOrphansView.swift
//  ArgosUI
//
//  Procesos de Claude huérfanos (Mac e iPhone/iPad): los que no cuelgan de ningún panel de
//  tmux ni son agentes persistentes. El usuario marca cuáles cerrar y confirma; el servidor
//  vuelve a comprobar cada uno justo antes de cada señal.
//

import SwiftUI

struct ClaudeOrphansView: View {
    @Bindable var model: ClaudeOrphansModel
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Procesos `claude` que no cuelgan de ningún panel de tmux, de una sesión SSH abierta ni de un agente de Argos: suelen quedar tras cerrarse mal un terminal o tras un OOM, y siguen ocupando memoria con sus servidores MCP.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.scan() }
        .confirmationDialog(confirmTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Cerrar procesos", role: .destructive) {
                Task { await model.killSelected() }
            }
        } message: {
            Text("Se les envía TERM y, si a los 5 segundos siguen vivos, KILL. Lo que estuvieran haciendo se pierde.")
        }
    }

    private var confirmTitle: String {
        let count = model.selection.count
        let memory = ResourceFormat.kilobytes(model.selectedRSSKB)
        return String(localized: "¿Cerrar los procesos marcados (\(count), \(memory))?")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .scanning:
            ProgressView("Buscando procesos…").frame(maxWidth: .infinity, minHeight: 60)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Reintentar") { Task { await model.scan() } }
            }
        case .loaded:
            if model.orphans.isEmpty {
                Label("No hay procesos de Claude huérfanos.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                orphanList
            }
            actions
        }
    }

    private var orphanList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.orphans) { orphan in
                OrphanRow(orphan: orphan, isSelected: model.selection.contains(orphan.pid)) {
                    model.toggle(orphan)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Buscar de nuevo", systemImage: "arrow.clockwise")
            }
            .disabled(model.isKilling)
            Spacer()
            if model.isKilling { ProgressView().controlSize(.small) }
            Button("Cerrar marcados", role: .destructive) { isConfirming = true }
                .disabled(!model.canKill)
        }
        .controlSize(.small)
    }
}

private struct OrphanRow: View {
    let orphan: ClaudeOrphan
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.red : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("claude · PID \(String(orphan.pid))").font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    if let directory = orphan.directory {
                        Label(directory, systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let command = orphan.command {
                        Text(verbatim: command)
                            .font(.caption.monospaced()).foregroundStyle(.tertiary)
                            .lineLimit(2).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                Text(ResourceFormat.kilobytes(orphan.totalRSSKB)).font(.callout.monospacedDigit())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var detail: String {
        let age = orphan.elapsedSeconds.map(ResourceFormat.uptime) ?? "?"
        let children = orphan.descendants
        if let tty = orphan.tty {
            return String(localized: "Hace \(age) · procesos hijos: \(children) · terminal \(tty)")
        }
        return String(localized: "Hace \(age) · procesos hijos: \(children) · sin terminal")
    }
}
