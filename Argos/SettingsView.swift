//
//  SettingsView.swift
//  Argos
//
//  Ventana de Ajustes (⌘,) con pestañas: apariencia del Terminal y Actualizaciones.
//

import Sparkle
import SwiftUI

struct SettingsView: View {
    let updater: SPUUpdater

    var body: some View {
        TabView {
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }

            UpdateSettingsView(updater: updater)
                .tabItem { Label("Actualizaciones", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 460)
    }
}

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
