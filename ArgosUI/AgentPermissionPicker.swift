//
//  AgentPermissionPicker.swift
//  Argos
//
//  Selector del modo de permisos de un proyecto (Mac, iPhone y iPad). Afecta a las
//  conversaciones nuevas: las abiertas conservan el modo con el que arrancaron.
//

import SwiftUI

struct AgentPermissionPicker: View {
    @AppStorage private var choice: String
    @AppStorage(AgentPermissionPreferences.globalKey)
    private var global = AgentPermissionPreferences.fallback.rawValue

    init(serverID: UUID, workingDirectory: String) {
        _choice = AppStorage(
            wrappedValue: AgentPermissionPreferences.useGlobalChoice,
            AgentPermissionPreferences.projectKey(serverID: serverID, workingDirectory: workingDirectory)
        )
    }

    private var globalMode: ClaudeAgentCommand.PermissionMode {
        AgentPermissionPreferences.storedGlobalMode(global)
    }

    private var effectiveMode: ClaudeAgentCommand.PermissionMode {
        AgentPermissionPreferences.storedProjectChoice(choice) ?? globalMode
    }

    var body: some View {
        Menu {
            Section("Para las conversaciones nuevas") {
                Picker("Permisos", selection: $choice) {
                    Text("Como en Ajustes (\(globalMode.title))")
                        .tag(AgentPermissionPreferences.useGlobalChoice)
                    ForEach(ClaudeAgentCommand.PermissionMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Label(effectiveMode.title, systemImage: effectiveMode.symbolName)
        }
        .help(effectiveMode.detail)
        .accessibilityLabel("Permisos de las conversaciones nuevas: \(effectiveMode.title)")
    }
}
