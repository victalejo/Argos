//
//  ClaudeLimitsScreen.swift
//  ArgosiOS
//
//  Pantalla del iPhone/iPad para activar o quitar la lectura de límites de uso de Claude
//  en un servidor (contenido compartido en `ClaudeLimitsSetupView`).
//

import SwiftUI

struct ClaudeLimitsScreen: View {
    let server: Server
    let viewModel: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var setup: ClaudeLimitsSetupModel

    init(server: Server, viewModel: SessionsViewModel) {
        self.server = server
        self.viewModel = viewModel
        _setup = State(initialValue: ClaudeLimitsSetupModel(service: viewModel.service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ClaudeLimitsSetupView(model: setup, status: viewModel.claudeLimits, serverName: server.name)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Límites de Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
            }
            .task { await viewModel.refreshServerReadings() }
        }
    }
}
