//
//  SessionContextSettingsView.swift
//  ArgosUI
//
//  «Contexto al arrancar Claude» de un servidor: explicación, interruptor y «Ver lo que
//  verá Claude» en un proyecto (Mac e iPhone/iPad; modelo en `SessionContextModel`).
//

import SwiftUI

struct SessionContextSettingsView: View {
    let model: SessionContextModel
    let projects: [Project]

    @State private var projectPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            explanation
            stateSection
            if model.isEnabled && !projects.isEmpty {
                previewSection
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.refresh() }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Al abrir Claude Code en un proyecto, Argos le da un resumen breve: el último CI de la rama, los cambios sin commit, los puertos abiertos, los encargos en cola, otros Claude en el mismo repositorio y lo que queda de tus límites.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Es un hook SessionStart en ~/.claude/settings.json (con copia en settings.json.argos-backup). Solo lee, tarda como mucho unos 3 segundos y no incluye secretos.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let enabled):
            Toggle("Contexto de Argos al arrancar Claude", isOn: toggleBinding(current: enabled))
                .disabled(model.isWorking)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reintentar") { Task { await model.refresh() } }
            }
        }
    }

    private func toggleBinding(current: Bool) -> Binding<Bool> {
        Binding<Bool>(
            get: { current },
            set: { (value: Bool) in Task { await model.setEnabled(value) } }
        )
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Proyecto", selection: $projectPath) {
                    ForEach(projects) { (project: Project) in
                        Text(project.name).tag(project.path)
                    }
                }
                .labelsHidden()
                Button("Ver lo que verá Claude") {
                    let path: String = selectedPath
                    Task { await model.loadPreview(projectPath: path) }
                }
                .disabled(model.isPreviewing)
                if model.isPreviewing { ProgressView().controlSize(.small) }
            }
            if let preview = model.preview {
                previewText(preview)
            }
        }
        .onAppear { if projectPath.isEmpty { projectPath = projects.first?.path ?? "" } }
    }

    private var selectedPath: String {
        projectPath.isEmpty ? (projects.first?.path ?? "") : projectPath
    }

    @ViewBuilder
    private func previewText(_ preview: SessionContextPreview) -> some View {
        if preview.isEmpty {
            Text("Ahora mismo Claude no recibiría nada en este proyecto.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(preview.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
