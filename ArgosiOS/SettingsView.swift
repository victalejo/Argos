//
//  SettingsView.swift
//  ArgosiOS
//
//  Ajustes de la app en iPhone/iPad: iCloud, comando de arranque de los proyectos (el
//  mismo ajuste y almacenamiento que «Ajustes → Proyectos» del Mac: `ProjectSettings`),
//  permisos de los agentes, avisos, atajos, Doctor de cada servidor y bloqueo con Face ID /
//  Touch ID.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppLock.self) private var lock
    @AppStorage(CloudServerSync.enabledKey) private var cloudSyncEnabled = true
    @AppStorage(AgentPermissionPreferences.globalKey)
    private var agentPermissionMode = AgentPermissionPreferences.fallback.rawValue
    @AppStorage(ShortcutPreferences.allowsUnconfirmedKey) private var shortcutsWithoutConfirmation = false
    @AppStorage(AppLockPolicy.exposesProjectsWhenLockedKey) private var exposesProjectsWhenLocked = false
    @State private var projectSettings = ProjectSettings.shared
    @State private var doctorServer: Server?
    @Environment(ServerHub.self) private var hub

    // Cuerpo en secciones pequeñas: el compilador de la CI (Swift 6.1) no comprueba a
    // tiempo un `Form` con todo dentro.
    var body: some View {
        NavigationStack {
            form
                .onChange(of: lock.isEnabled) { (_: Bool, _: Bool) in ProjectShortcutIndex.refreshExposure() }
                .onChange(of: exposesProjectsWhenLocked) { (_: Bool, _: Bool) in ProjectShortcutIndex.refreshExposure() }
                .sheet(item: $doctorServer) { (server: Server) in
                    DoctorScreen(service: hub.viewModel(for: server).service, serverName: server.name, knownServers: hub.store.servers)
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

    private var form: some View {
        Form {
            startupSection
            agentsSection
            shortcutsSection
            doctorSection
            cloudSection
            securitySection
        }
    }

    private var startupSection: some View {
        Section {
            StartupCommandPicker(command: $projectSettings.defaultStartupCommand)
        } header: {
            Text("Al abrir un proyecto")
        } footer: {
            Text(StartupCommandPicker.explanation)
        }
    }

    private var agentsSection: some View {
        Section("Agentes") {
            Picker(selection: $agentPermissionMode) {
                ForEach(ClaudeAgentCommand.PermissionMode.allCases, id: \.self) { (mode: ClaudeAgentCommand.PermissionMode) in
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
    }

    private var shortcutsSection: some View {
        Section {
            Toggle(isOn: $shortcutsWithoutConfirmation) {
                Label("Permitir atajos sin confirmar", systemImage: "bolt.badge.checkmark")
            }
        } header: {
            Text("Atajos y Siri")
        } footer: {
            Text("«Pedir a Claude» confirma antes de mandar un encargo a un agente que trabaja sin preguntar o que acepta ediciones solo. Actívalo solo si usas esos atajos en automatizaciones y sabes lo que hacen. No desactiva el bloqueo con \(AppLock.biometryName).")
        }
    }

    @ViewBuilder
    private var doctorSection: some View {
        if !hub.store.servers.isEmpty {
            Section {
                ForEach(hub.store.servers) { (server: Server) in
                    Button {
                        doctorServer = server
                    } label: {
                        Label(server.name, systemImage: "stethoscope")
                    }
                    .disabled(ImportedKeyStore.needsImport(server))
                }
            } header: {
                Text("Doctor del servidor")
            } footer: {
                Text("Comprueba la conexión, tmux, Claude Code y los avisos de un servidor, y copia un diagnóstico.")
            }
        }
    }

    private var cloudSection: some View {
        Section {
            Toggle(isOn: $cloudSyncEnabled) {
                Label("Sincronizar con iCloud", systemImage: "icloud")
            }
        } footer: {
            Text("Servidores y huellas, con tu Mac y tus otros dispositivos. Las contraseñas y claves no viajan.")
        }
    }

    private var lockBinding: Binding<Bool> {
        Binding<Bool>(
            get: { lock.isEnabled },
            set: { (value: Bool) in Task { await lock.setEnabled(value) } }
        )
    }

    private var securitySection: some View {
        Section {
            Toggle(isOn: lockBinding) {
                Label("Pedir \(AppLock.biometryName) al abrir", systemImage: "faceid")
            }
            if lock.isEnabled {
                Toggle(isOn: $exposesProjectsWhenLocked) {
                    Label("Mostrar proyectos en Spotlight y Siri", systemImage: "magnifyingglass")
                }
            }
        } header: {
            Text("Seguridad")
        } footer: {
            Text(securityFooter)
        }
    }

    private var securityFooter: String {
        String(localized: "Argos da acceso a tus servidores. Con esto activado, pide \(AppLock.biometryName) al abrir la app y al volver tras más de un minuto fuera, oculta su contenido en el selector de apps y lo pide también al usar «Pedir a Claude». Sin «Mostrar proyectos», los nombres de tus proyectos no salen en Spotlight ni en las sugerencias de Siri (los atajos ya creados siguen funcionando).")
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
        (String(localized: "Ninguno"), ""),
    ]

    static let explanation = String(localized: "Se teclea en la sesión nueva del proyecto. «--continue» retoma la última conversación de Claude Code en esa carpeta. «cc» es un alias que muchos definen para «claude» en su ~/.bashrc o ~/.zshrc; Claude Code no lo instala: si tu servidor no lo tiene, elige «claude --continue».")

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
