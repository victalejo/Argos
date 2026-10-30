//
//  ProjectSettingsView.swift
//  Argos
//
//  Pestaña "Proyectos" de Ajustes: comando que se lanza al abrir un proyecto (salvo
//  que el proyecto tenga uno propio).
//

import SwiftUI

struct ProjectSettingsView: View {
    @State private var settings = ProjectSettings.shared

    var body: some View {
        Form {
            Section {
                TextField("Comando al abrir", text: $settings.defaultStartupCommand, prompt: Text("nada"))
                    .font(.body.monospaced())
                Picker("Atajos", selection: presetBinding) {
                    ForEach(ProjectSettings.presets, id: \.command) { preset in
                        Text(preset.label).tag(Optional(preset.command))
                    }
                    if presetBinding.wrappedValue == nil {
                        Text("Personalizado").tag(String?.none)
                    }
                }
            } header: {
                Text("Al abrir un proyecto detenido")
            } footer: {
                Text("Se teclea en la terminal del proyecto, ya situada en su carpeta, así que "
                     + "funcionan tus alias (p. ej. cc). Con --continue Claude retoma la última "
                     + "conversación de esa carpeta. Cada proyecto puede usar otro comando "
                     + "desde \"Editar proyecto…\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restablecer (\(ProjectSettings.factoryStartupCommand))") {
                    settings.defaultStartupCommand = ProjectSettings.factoryStartupCommand
                }
                .disabled(settings.defaultStartupCommand == ProjectSettings.factoryStartupCommand)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// Atajo seleccionado si el comando coincide con uno; `nil` = personalizado.
    private var presetBinding: Binding<String?> {
        Binding(
            get: {
                let current = settings.defaultStartupCommand
                return ProjectSettings.presets.contains { $0.command == current } ? current : nil
            },
            set: { if let command = $0 { settings.defaultStartupCommand = command } }
        )
    }
}
