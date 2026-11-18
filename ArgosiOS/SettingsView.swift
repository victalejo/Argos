//
//  SettingsView.swift
//  ArgosiOS
//
//  Ajustes de la app en iPhone/iPad: iCloud, comando de arranque de los proyectos (el
//  mismo ajuste y almacenamiento que «Ajustes → Proyectos» del Mac: `ProjectSettings`),
//  permisos de los agentes, avisos y bloqueo con Face ID / Touch ID.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppLock.self) private var lock
    @AppStorage(CloudServerSync.enabledKey) private var cloudSyncEnabled = true
    @AppStorage(AgentPermissionPreferences.globalKey)
    private var agentPermissionMode = AgentPermissionPreferences.fallback.rawValue
    @State private var projectSettings = ProjectSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StartupCommandPicker(command: $projectSettings.defaultStartupCommand)
                } header: {
                    Text("Al abrir un proyecto")
                } footer: {
                    Text(StartupCommandPicker.explanation)
                }

                Section("Agentes") {
                    Picker(selection: $agentPermissionMode) {
                        ForEach(ClaudeAgentCommand.PermissionMode.allCases, id: \.self) { mode in
                            Label(mode.title, systemImage: mode.symbolName).tag(mode.rawValue)
                        }
                    } label: {
                        Label("Permisos de los agentes", systemImage: "sparkles")
                    }
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Avisos", systemImage: "bell.badge")
                    }
                }

                Section {
                    Toggle(isOn: $cloudSyncEnabled) {
                        Label("Sincronizar con iCloud", systemImage: "icloud")
                    }
                } footer: {
                    Text("Servidores y huellas, con tu Mac y tus otros dispositivos. Las contraseñas y claves no viajan.")
                }

                Section {
                    Toggle(isOn: Binding(get: { lock.isEnabled }, set: { value in Task { await lock.setEnabled(value) } })) {
                        Label("Pedir \(AppLock.biometryName) al abrir", systemImage: "faceid")
                    }
                } header: {
                    Text("Seguridad")
                } footer: {
                    Text("Argos da acceso a tus servidores. Con esto activado, pide \(AppLock.biometryName) al abrir la app y al volver tras más de un minuto fuera, y oculta su contenido en el selector de apps.")
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hecho") { dismiss() }
                }
            }
        }
    }
}

/// Comando que se teclea al abrir un proyecto (`""` = nada), con preajustes y uno a mano.
struct StartupCommandPicker: View {
    @Binding var command: String
    @State private var custom = ""
    @State private var isCustom = false

    /// Preajustes del iPhone: el primero funciona sin alias.
    static let presets: [(label: String, command: String)] = [
        ("claude --continue", "claude --continue"),
        ("cc --continue (alias)", "cc --continue"),
        ("Ninguno", ""),
    ]

    static let explanation = "Se teclea en la sesión nueva del proyecto. «--continue» retoma la última "
        + "conversación de Claude Code en esa carpeta. «cc» es un alias que muchos definen para «claude» "
        + "en su ~/.bashrc o ~/.zshrc; Claude Code no lo instala: si tu servidor no lo tiene, elige «claude --continue»."

    private var selection: Binding<String> {
        Binding(
            get: { isCustom ? "\u{0}personalizado" : command },
            set: { value in
                if value == "\u{0}personalizado" {
                    isCustom = true
                    custom = command
                } else {
                    isCustom = false
                    command = value
                }
            }
        )
    }

    var body: some View {
        Picker("Comando", selection: selection) {
            ForEach(Self.presets, id: \.command) { preset in
                Text(preset.label).tag(preset.command)
            }
            if !isCustom, !Self.presets.contains(where: { $0.command == command }) {
                Text(command).tag(command)
            }
            Text("Personalizado…").tag("\u{0}personalizado")
        }
        if isCustom {
            TextField("Comando", text: $custom, prompt: Text("npm run dev, claude…"))
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { command = custom.trimmingCharacters(in: .whitespacesAndNewlines) }
                .onChange(of: custom) { _, value in command = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}
