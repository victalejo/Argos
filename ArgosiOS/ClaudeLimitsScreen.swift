//
//  ClaudeLimitsScreen.swift
//  ArgosiOS
//
//  Pantalla del iPhone/iPad para activar o quitar la lectura de límites de uso de Claude
//  en un servidor (contenido compartido en `ClaudeLimitsSetupView`) y el contexto que Argos
//  le da a Claude al arrancar (`SessionContextSettingsView`).
//

import SwiftUI

struct ClaudeLimitsScreen: View {
    let server: Server
    let viewModel: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var setup: ClaudeLimitsSetupModel
    @State private var usage: ClaudeUsageModel
    @State private var context: SessionContextModel

    init(server: Server, viewModel: SessionsViewModel) {
        self.server = server
        self.viewModel = viewModel
        _setup = State(initialValue: ClaudeLimitsSetupModel(service: viewModel.service))
        _usage = State(initialValue: ClaudeUsageModel(service: viewModel.service, projects: viewModel.projects))
        _context = State(initialValue: SessionContextModel(service: viewModel.service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Uso").font(.headline)
                    ClaudeUsageView(model: usage)
                    Text("Límites de la suscripción").font(.headline)
                    ClaudeLimitsSetupView(model: setup, status: viewModel.claudeLimits, serverName: server.name)
                    Text("Contexto al arrancar Claude").font(.headline)
                    SessionContextSettingsView(model: context, projects: viewModel.projects)
                }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Uso y límites de Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
            }
            .task { await viewModel.refreshServerReadings() }
        }
    }
}
