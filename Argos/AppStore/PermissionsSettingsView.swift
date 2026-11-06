//
//  PermissionsSettingsView.swift
//  Argos
//
//  Ajustes → Permisos (canal App Store): lo que en el canal GitHub conceden las
//  excepciones de sandbox, aquí lo concede el usuario una vez y lo puede revocar.
//

import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var sshStatus = SSHDirectoryAccess.currentStatus()
    @State private var scriptInstalled = TerminalScriptBridge.isInstalled()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceIcon(symbol: "lock.shield", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permisos de Argos").font(.headline)
                    Text("Argos funciona en un entorno protegido de macOS. Concede solo lo que uses.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)

            Form {
                Section {
                    LabeledContent {
                        sshButton
                    } label: {
                        Label("Carpeta ~/.ssh", systemImage: "key")
                        Text(sshDescription).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Para importar hosts de ~/.ssh/config y usar las claves que referencia. Solo lectura.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent {
                        scriptButton
                    } label: {
                        Label("Abrir en Terminal con Claude Code", systemImage: "terminal")
                        Text(scriptInstalled ? "Script instalado" : "Sin instalar")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Un pequeño AppleScript que guardas tú en la carpeta de scripts de Argos. "
                         + "macOS te pedirá además permiso para que Argos controle Terminal.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let message {
                    Text(message).font(.callout).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)
        }
    }

    private var sshDescription: String {
        switch sshStatus {
        case .granted: return "Acceso concedido"
        case .implicit: return "Accesible"
        case .needsGrant: return "Sin acceso"
        }
    }

    @ViewBuilder
    private var sshButton: some View {
        if sshStatus == .granted {
            Button("Revocar") {
                SSHDirectoryAccess.revoke()
                refresh()
            }
        } else {
            Button("Conceder acceso…") {
                if case .failed(let error) = SSHDirectoryGrant.request() { message = error }
                refresh()
            }
        }
    }

    @ViewBuilder
    private var scriptButton: some View {
        if scriptInstalled {
            Button("Mostrar en Finder") { TerminalScriptBridge.revealInFinder() }
        } else {
            Button("Instalar script…") {
                do {
                    _ = try TerminalScriptBridge.install()
                } catch {
                    message = error.localizedDescription
                }
                refresh()
            }
        }
    }

    private func refresh() {
        sshStatus = SSHDirectoryAccess.currentStatus()
        scriptInstalled = TerminalScriptBridge.isInstalled()
    }
}

/// Ajustes → Actualizaciones en el canal App Store: las entrega la propia App Store.
struct AppStoreUpdateSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceIcon(symbol: "arrow.triangle.2.circlepath", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Argos, siempre al día").font(.headline)
                    Text("Las actualizaciones llegan por la App Store.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(22)

            Form {
                Section {
                    HStack {
                        Text("Versión \(Bundle.main.shortVersion)")
                        Spacer()
                        Button("Abrir en App Store…") { NSWorkspace.shared.open(AppStoreLinks.productPage) }
                    }
                } footer: {
                    Text("Activa las actualizaciones automáticas en App Store → Ajustes para recibirlas sin hacer nada.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
