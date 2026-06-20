//
//  RemoteLoginSheet.swift
//  Argos
//
//  Hoja que corre `claude auth login --claudeai` en el SERVIDOR dentro de un PTY
//  embebido (SwiftTerm). El usuario ve el flujo OAuth real: copia el enlace, lo abre
//  en su navegador, autoriza y pega el código. Reutiliza `LiveTerminalController` en
//  modo comando, así clic/selección de enlace y pegado funcionan igual que el terminal.
//

import SwiftUI

struct RemoteLoginSheet: View {
    let service: any SSHServicing
    /// Comando ya construido, p. ej. `'/home/u/.local/bin/claude' auth login --claudeai`.
    let command: String
    let onClose: () -> Void

    @State private var controller: LiveTerminalController?
    @State private var settings = TerminalSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terminalArea
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .task {
            if controller == nil {
                controller = LiveTerminalController(service: service, command: command)
            }
        }
        .onDisappear { controller?.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Iniciar sesión de Claude en el servidor", systemImage: "person.badge.key")
                .font(.headline)
            Text("Copia el enlace que aparezca abajo, ábrelo en tu navegador, autoriza con tu "
                 + "cuenta (Plan Max) y pega el código aquí. Esto inicia sesión en ESTE "
                 + "servidor; usa tu suscripción, nunca la API.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private var terminalArea: some View {
        if let controller {
            TerminalViewRepresentable(
                controller: controller,
                fontSize: settings.fontSize,
                theme: settings.theme
            )
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Listo") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
