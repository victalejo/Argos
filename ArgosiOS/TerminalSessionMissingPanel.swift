//
//  TerminalSessionMissingPanel.swift
//  ArgosiOS
//
//  Lo que se ve en el terminal cuando la sesión tmux ya no existe en el servidor: en vez
//  de «Reconectar» (que volvería a fallar), ofrece iniciar el proyecto de nuevo.
//

import SwiftUI

struct TerminalSessionMissingPanel: View {
    let message: String
    let controller: TouchTerminalController
    let viewModel: SessionsViewModel
    let sessionName: String

    @State private var isStarting = false
    @State private var startError: String?
    @State private var memoryConfirmation: MemoryStartConfirmation?

    private var project: Project? {
        viewModel.projectListing.entries.first { $0.project.sessionName == sessionName }?.project
    }

    var body: some View {
        ContentUnavailableView {
            Label("La sesión terminó", systemImage: "stop.circle")
        } description: {
            Text(startError ?? message)
        } actions: {
            actions
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07))
        .memoryPressureConfirmation($memoryConfirmation)
    }

    @ViewBuilder
    private var actions: some View {
        if let project {
            Button {
                if let pressure = viewModel.memoryPressure, pressure.needsConfirmationToStart {
                    memoryConfirmation = MemoryStartConfirmation(pressure: pressure) { start(project) }
                } else {
                    start(project)
                }
            } label: {
                if isStarting {
                    ProgressView()
                } else {
                    Text("Iniciar de nuevo")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isStarting)
        } else {
            Button("Reconectar") { controller.reconnectManually() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func start(_ project: Project) {
        isStarting = true
        startError = nil
        Task {
            defer { isStarting = false }
            do {
                try await viewModel.openProject(
                    project,
                    defaultStartupCommand: ProjectSettings.shared.defaultStartupCommand
                )
                controller.reconnectManually()
            } catch {
                startError = error.userMessage
            }
        }
    }
}
