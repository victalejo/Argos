//
//  NotificationSettingsView.swift
//  ArgosiOS
//
//  «Avisos» (como `BackgroundSettingsDialog` de Android): qué avisa Argos, que en
//  segundo plano llegan cuando iOS lo permite (BGAppRefreshTask: iOS decide cuándo; no
//  corre si se cierra la app desde el selector, sin actualización en segundo plano o en
//  bajo consumo), y el estado REAL leído del sistema con un enlace a Ajustes cuando algo
//  lo impide. El permiso se pide aquí, desde un botón.
//

import SwiftUI
import UIKit

struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var readiness: NotificationReadiness?
    @State private var isRequesting = false

    var body: some View {
        Form {
            Section {
                Label("Claude terminó de responder", systemImage: "checkmark.circle")
                Label("Claude espera tu permiso o una respuesta", systemImage: "bell.badge")
                Label("Un agente de Argos terminó o necesita algo", systemImage: "sparkles")
                Label("El CI de un commit pasó o falló (con la app abierta)", systemImage: "checkmark.seal")
            } header: {
                Text("Qué te avisa Argos")
            } footer: {
                Text("Claude en el terminal necesita el «indicador de Claude» del servidor (menú del servidor → Activar indicador de Claude).")
            }

            Section {
                if let readiness {
                    Label(readiness.summary, systemImage: readiness.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(readiness.isReady ? .green : .orange)
                    ForEach(readiness.issues) { issue in
                        issueRow(issue)
                    }
                    statusRows(readiness)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Estado en este dispositivo")
            }

            Section {
                Text("Con Argos abierto, los avisos son inmediatos. En segundo plano, iOS deja a Argos revisar tus servidores de vez en cuando (cada 15 minutos como pronto; la frecuencia la decide iOS según cómo uses la app). No hay servidor intermedio de Argos: sin él no hay notificaciones push, así que si cierras la app desde el selector de apps, desactivas la actualización en segundo plano o activas el modo de bajo consumo, los avisos esperan a que vuelvas a abrirla.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Cómo llegan")
            }
        }
        .navigationTitle("Avisos")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            // Al volver de Ajustes se relee el estado.
            if scenePhase == .active { readiness = await AgentNotifier.shared.readiness() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            Task { readiness = await AgentNotifier.shared.readiness() }
        }
    }

    private func issueRow(_ issue: NotificationReadiness.Issue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.title).font(.subheadline.weight(.semibold))
            Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
            if issue == .permissionNotRequested {
                Button("Activar avisos") { requestPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRequesting)
            } else if issue.needsSettings {
                Button("Abrir Ajustes") { openSettings(for: issue) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusRows(_ readiness: NotificationReadiness) -> some View {
        LabeledContent("Notificaciones", value: permissionText(readiness.permission))
        LabeledContent("Actualización en segundo plano", value: refreshText(readiness.backgroundRefresh))
        LabeledContent("Modo de bajo consumo", value: readiness.lowPowerMode ? "Activado" : "Desactivado")
    }

    private func permissionText(_ permission: NotificationPermission) -> String {
        switch permission {
        case .notDetermined: return "Sin pedir"
        case .denied: return "Desactivadas"
        case .authorized: return "Permitidas"
        case .quiet: return "Silenciosas"
        }
    }

    private func refreshText(_ availability: BackgroundRefreshAvailability) -> String {
        switch availability {
        case .available: return "Activada"
        case .denied: return "Desactivada"
        case .restricted: return "Restringida"
        }
    }

    private func requestPermission() {
        isRequesting = true
        Task {
            await AgentNotifier.shared.requestAuthorizationFromUserAction()
            readiness = await AgentNotifier.shared.readiness()
            isRequesting = false
        }
    }

    /// Notificaciones: su página de Ajustes; segundo plano: la página de Argos.
    private func openSettings(for issue: NotificationReadiness.Issue) {
        let target = issue.blocksAllNotices ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
        if let url = URL(string: target) { UIApplication.shared.open(url) }
    }
}
