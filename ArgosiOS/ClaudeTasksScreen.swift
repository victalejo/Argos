//
//  ClaudeTasksScreen.swift
//  ArgosiOS
//
//  Pantalla «Encargos» de un proyecto en iPhone/iPad (contenido compartido en
//  `ClaudeTasksView`).
//

import SwiftUI

struct ClaudeTasksScreen: View {
    let project: Project
    let viewModel: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var model: ClaudeTasksModel
    @State private var schedules: ClaudeSchedulesModel

    init(project: Project, viewModel: SessionsViewModel, serverID: Server.ID) {
        self.project = project
        self.viewModel = viewModel
        _model = State(initialValue: ClaudeTasksModel(
            service: viewModel.service,
            serverID: serverID,
            project: project,
            claudeWindows: viewModel.claudeActivity.windows(forSession: project.sessionName)
        ))
        _schedules = State(initialValue: ClaudeSchedulesModel(service: viewModel.service, serverID: serverID, project: project))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ClaudeTasksView(model: model)
                    Divider()
                    Text("Tareas programadas").font(.headline)
                    ClaudeSchedulesView(model: schedules)
                }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Encargos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
            }
        }
    }
}
