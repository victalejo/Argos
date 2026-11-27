//
//  PromptLibraryScreen.swift
//  ArgosiOS
//
//  Pantalla «Biblioteca de encargos» de un proyecto en iPhone/iPad (contenido compartido
//  en `PromptLibraryView`).
//

import SwiftUI

struct PromptLibraryScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PromptLibraryModel

    init(project: Project, viewModel: SessionsViewModel) {
        _model = State(initialValue: PromptLibraryModel(
            service: viewModel.service,
            project: project,
            library: viewModel.promptLibrary,
            claudeWindows: viewModel.claudeActivity.windows(forSession: project.sessionName),
            onReport: { [weak viewModel] (report: ProjectsLoadReport) in viewModel?.applyProjectsReport(report) }
        ))
    }

    var body: some View {
        NavigationStack {
            PromptLibraryView(model: model)
                .navigationTitle("Biblioteca de encargos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                }
        }
    }
}
