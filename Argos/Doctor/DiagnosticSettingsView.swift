//
//  DiagnosticSettingsView.swift
//  Argos
//
//  Pestaña «Diagnóstico» de Ajustes: copia un informe (versión, sistema y registro reciente de
//  la app) para pegarlo en un issue. El resultado del Doctor de un servidor concreto se añade
//  desde la hoja del Doctor (ahí sí hay un servidor conectado).
//

import AppKit
import SwiftUI

struct DiagnosticSettingsView: View {
    @State private var includesPersonalData = false
    @State private var includesTechnicalDetail = false
    @State private var state: CopyState = .idle

    private enum CopyState { case idle, working, copied }

    var body: some View {
        Form {
            Section {
                Toggle("Incluir nombres de servidor, usuarios e IPs", isOn: $includesPersonalData)
                Toggle("Incluir detalle técnico del registro (puede contener texto del servidor)", isOn: $includesTechnicalDetail)
            } header: {
                Text("Informe de diagnóstico")
            } footer: {
                Text(String(localized: "Incluye la versión de Argos, tu sistema y los últimos minutos del registro de la app. Por defecto los servidores, usuarios e IPs se sustituyen por marcadores como «servidor-1». Argos oculta las claves, tokens y contraseñas que reconoce, pero no puede garantizar que no se escape alguno: revisa el texto antes de publicarlo. Para añadir el estado de un servidor, abre su Doctor desde el menú del servidor."))
            }
            Section {
                Button {
                    Task { await copy() }
                } label: {
                    switch state {
                    case .idle: Label("Copiar diagnóstico", systemImage: "doc.on.doc")
                    case .working: Label("Preparando…", systemImage: "hourglass")
                    case .copied: Label("Copiado al portapapeles", systemImage: "checkmark")
                    }
                }
                .disabled(state == .working)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func copy() async {
        state = .working
        // Solo se leen los nombres para redactarlos; esta instancia nunca escribe.
        let servers = ServerStore().servers.map(DiagnosticRedactor.KnownServer.init)
        let text = await DiagnosticReport.collect(
            doctor: nil, serverName: nil, knownServers: servers, includePersonalData: includesPersonalData,
            includesTechnicalDetail: includesTechnicalDetail
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state = .copied
        try? await Task.sleep(for: .seconds(2))
        state = .idle
    }
}
