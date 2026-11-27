//
//  PromptLibrarySheet.swift
//  Argos
//
//  Hoja del Mac «Biblioteca de encargos» de un proyecto (contenido compartido en
//  `PromptLibraryView`).
//

import SwiftUI

struct PromptLibrarySheet: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @State private var model: PromptLibraryModel

    init(project: Project, vm: SessionsViewModel) {
        self.project = project
        _model = State(initialValue: PromptLibraryModel(
            service: vm.service,
            project: project,
            library: vm.promptLibrary,
            claudeWindows: vm.claudeActivity.windows(forSession: project.sessionName),
            onReport: { [weak vm] (report: ProjectsLoadReport) in vm?.applyProjectsReport(report) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Biblioteca de encargos").font(.title2.weight(.semibold))
                Text(project.name).font(.callout).foregroundStyle(.secondary)
            }
            PromptLibraryView(model: model)
            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 620)
    }
}
