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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                WorkspaceIcon(symbol: "folder.fill", size: 80)

                VStack(spacing: 6) {
                    Text(project.name).font(.system(size: 28, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center).textSelection(.enabled)
                    if let group = project.group {
                        Text(group).font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Tu proyecto está listo. Ábrelo para continuar.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .multilineTextAlignment(.center)
                }

                Button(action: open) {
                    HStack(spacing: 8) {
                        if isOpening { ProgressView().controlSize(.small) }
                        else { Image(systemName: "play.fill").font(.caption) }
                        Text(isOpening ? "Abriendo…" : "Abrir proyecto")
                        if !isOpening { Text("↵").opacity(0.7).accessibilityHidden(true) }
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isOpening)
                Text("La sesión se inicia en la carpeta del proyecto.")
                    .font(.caption).foregroundStyle(.secondary)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 6) {
                        Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text("DETENIDO")
                            .font(.system(size: 10, weight: .semibold)).tracking(1)
                            .foregroundStyle(.secondary)
                    }
                    detailRow("Carpeta", value: project.path, icon: "folder")
                    Divider()
                    detailRow("Al abrir", value: commandDescription, icon: "terminal")
                }
                .padding(22)
                .background(ArgosTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(ArgosTheme.border) }



            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceBackdrop())
        .animation(ArgosTheme.motion(reduceMotion: reduceMotion), value: isOpening)
        .animation(ArgosTheme.motion(reduceMotion: reduceMotion), value: errorMessage)
    }

    private var commandDescription: String {
        project.resolvedStartupCommand(default: settings.defaultStartupCommand) ?? "Solo abrir la terminal"
    }

    private func detailRow(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
