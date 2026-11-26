//
//  ClaudeTasksSheet.swift
//  Argos
//
//  Hoja del Mac «Encargos» de un proyecto (contenido compartido en `ClaudeTasksView`).
//

import SwiftUI

struct ClaudeTasksSheet: View {
    let project: Project
    let vm: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var model: ClaudeTasksModel

    init(project: Project, vm: SessionsViewModel) {
        self.project = project
        self.vm = vm
        _model = State(initialValue: ClaudeTasksModel(
            service: vm.service,
            project: project,
            claudeWindows: vm.claudeActivity.windows(forSession: project.sessionName)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Encargos").font(.title2.weight(.semibold))
                Text(project.name).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                ClaudeTasksView(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }
}
