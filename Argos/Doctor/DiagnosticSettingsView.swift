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
    @State private var state: CopyState = .idle

    private enum CopyState { case idle, working, copied }

    var body: some View {
        Form {
            Section {
                Toggle("Incluir nombres de servidor, usuarios e IPs", isOn: $includesPersonalData)
            } header: {
                Text("Informe de diagnóstico")
            } footer: {
                Text("Incluye la versión de Argos, tu sistema y los últimos minutos del registro de la app. "
                     + "Por defecto los servidores, usuarios e IPs se sustituyen por marcadores como «servidor-1». "
                     + "Las claves, tokens y contraseñas nunca se incluyen. Para añadir el estado de un servidor, "
                     + "abre su Doctor desde el menú del servidor.")
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
            doctor: nil, serverName: nil, knownServers: servers, includePersonalData: includesPersonalData
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state = .copied
        try? await Task.sleep(for: .seconds(2))
        state = .idle
    }
}
