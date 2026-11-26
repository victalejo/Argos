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

    init(project: Project, viewModel: SessionsViewModel) {
        self.project = project
        self.viewModel = viewModel
        _model = State(initialValue: ClaudeTasksModel(
            service: viewModel.service,
            project: project,
            claudeWindows: viewModel.claudeActivity.windows(forSession: project.sessionName)
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ClaudeTasksView(model: model)
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
