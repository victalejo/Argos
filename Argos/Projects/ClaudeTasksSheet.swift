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
    @State private var schedules: ClaudeSchedulesModel

    init(project: Project, vm: SessionsViewModel, serverID: Server.ID) {
        self.project = project
        self.vm = vm
        _model = State(initialValue: ClaudeTasksModel(
            service: vm.service,
            serverID: serverID,
            project: project,
            claudeWindows: vm.claudeActivity.windows(forSession: project.sessionName),
            savedPrompts: vm.promptLibrary.prompts(forProject: project.id)
        ))
        _schedules = State(initialValue: ClaudeSchedulesModel(
            service: vm.service, serverID: serverID, project: project,
            savedPrompts: vm.promptLibrary.prompts(forProject: project.id)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Encargos").font(.title2.weight(.semibold))
                Text(project.name).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ClaudeTasksView(model: model)
                    Divider()
                    Text("Tareas programadas").font(.headline)
                    ClaudeSchedulesView(model: schedules)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 680)
    }
}
