//
//  SettingsView.swift
//  Argos
//
//  Ventana de Ajustes (⌘,) con pestañas: Terminal, Proyectos, Actualizaciones y (en el
//  canal App Store) Permisos.
//

#if !APPSTORE
import Sparkle
#endif
import SwiftUI

struct SettingsView: View {
    #if !APPSTORE
    let updater: SPUUpdater
    #endif

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Apariencia", systemImage: "paintpalette") }

            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }

            ProjectSettingsView()
                .tabItem { Label("Proyectos", systemImage: "folder") }

            // Un `#if` por pestaña y con UNA sola vista: si un bloque `#if` agrupa
            // varias, el TabView de Ajustes en macOS solo muestra la última.
            #if APPSTORE
            PermissionsSettingsView()
                .tabItem { Label("Permisos", systemImage: "lock.shield") }
            #endif

            updatesTab
                .tabItem { Label("Actualizaciones", systemImage: "arrow.triangle.2.circlepath") }
        }
        .tint(ArgosTheme.controlAccent)
        .frame(width: 540, height: 480)
    }

    /// Sparkle en el canal GitHub; la ficha de la App Store en el otro.
    @ViewBuilder
    private var updatesTab: some View {
        #if APPSTORE
        AppStoreUpdateSettingsView()
        #else
        UpdateSettingsView(updater: updater)
        #endif
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceIcon(symbol: "paintpalette", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tu espacio, tu estilo").font(.headline)
                    Text("Elige la apariencia que te resulte más cómoda.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
            Form {
                Section {
                    Picker("Apariencia", selection: $appearance) {
                        Label("Sistema", systemImage: "desktopcomputer").tag("system")
                        Label("Clara", systemImage: "sun.max").tag("light")
                        Label("Oscura", systemImage: "moon").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("Apariencia de la aplicación")
                } footer: {
                    Text("El tema del terminal se configura por separado en la pestaña Terminal.")
                }
                Section("Muévete más rápido") {
                    shortcut("Buscar una sesión", keys: "⌘ K")
                    shortcut("Buscar proyectos", keys: "⌘ F")
                    shortcut("Crear un proyecto", keys: "⌘ N")
                    shortcut("Buscar archivos", keys: "⌘ P")
                }
                Section {
                    Label("Las animaciones respetan Reducir movimiento de macOS.", systemImage: "accessibility")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            KeyboardHint(keys: keys)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(keys)")
    }
}

#if !APPSTORE
/// Pestaña de actualizaciones: enlaza con el actualizador de Sparkle.
struct UpdateSettingsView: View {
    let updater: SPUUpdater

    @State private var autoCheck: Bool
    @State private var autoDownload: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _autoCheck = State(initialValue: updater.automaticallyChecksForUpdates)
        _autoDownload = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceIcon(symbol: "arrow.triangle.2.circlepath", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Argos, siempre al día").font(.headline)
                    Text("Elige cómo recibir las próximas mejoras.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)
        Form {
            Section {
                Toggle("Buscar actualizaciones automáticamente", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, value in
                        updater.automaticallyChecksForUpdates = value
                        if !value { autoDownload = false }
                    }

                Toggle("Descargar e instalar automáticamente", isOn: $autoDownload)
                    .onChange(of: autoDownload) { _, value in
                        updater.automaticallyDownloadsUpdates = value
                    }
                    .disabled(!autoCheck)
            } footer: {
                Text("Las actualizaciones se publican en GitHub Releases y se verifican con firma EdDSA antes de instalarse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Buscar ahora…") { updater.checkForUpdates() }
                    Spacer()
                    if let last = updater.lastUpdateCheckDate {
                        Text("Última comprobación: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        }
    }
}
#endif
