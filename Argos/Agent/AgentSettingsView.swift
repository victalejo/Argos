//
//  AgentSettingsView.swift
//  Argos
//
//  Pestaña «Agente» de Ajustes: modo de permisos por defecto de los agentes.
//

import SwiftUI

struct AgentSettingsView: View {
    @AppStorage(AgentPermissionPreferences.globalKey)
    private var mode = AgentPermissionPreferences.fallback.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceIcon(symbol: "sparkles", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tu agente, tus reglas").font(.headline)
                    Text("Decide qué puede hacer Claude sin preguntarte.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
            Form {
                Section {
                    Picker("Modo de permisos", selection: $mode) {
                        ForEach(ClaudeAgentCommand.PermissionMode.allCases, id: \.self) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("Modo de permisos por defecto")
                } footer: {
                    Text("Cada proyecto puede usar otro desde el panel del agente. Se aplica a las conversaciones nuevas.")
                }
            }
            .formStyle(.grouped)
        }
    }
}
