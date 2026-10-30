//
//  ProjectStoppedView.swift
//  Argos
//
//  Detalle de un proyecto DETENIDO (sin sesión tmux): muestra su carpeta y el comando
//  de arranque, y lo abre con un clic (o ⏎). Al abrirse aparece su sesión y la vista
//  pasa sola al terminal en vivo.
//

import SwiftUI

struct ProjectStoppedView: View {
    let project: Project
    let vm: SessionsViewModel

    @State private var settings = ProjectSettings.shared
    @State private var isOpening = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text(project.name).font(.title.weight(.semibold))
                if let group = project.group {
                    Text(group).font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                detailRow("Carpeta", value: project.path, icon: "folder")
                detailRow("Al abrir", value: commandDescription, icon: "terminal")
                detailRow("Estado", value: "Detenido · no consume recursos en el servidor", icon: "pause.circle")
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: open) {
                HStack(spacing: 8) {
                    if isOpening { ProgressView().controlSize(.small) }
                    Text(isOpening ? "Abriendo…" : "Abrir proyecto")
                }
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isOpening)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commandDescription: String {
        project.resolvedStartupCommand(default: settings.defaultStartupCommand) ?? "Solo abrir la terminal"
    }

    private func detailRow(_ label: String, value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(label, systemImage: icon)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func open() {
        isOpening = true
        errorMessage = nil
        Task {
            do {
                try await vm.openProject(project, defaultStartupCommand: settings.defaultStartupCommand)
            } catch {
                errorMessage = error.userMessage
            }
            isOpening = false
        }
    }
}
