//
//  SessionContextSettingsView.swift
//  ArgosUI
//
//  «Contexto al arrancar Claude» de un servidor: explicación, interruptor y «Ver lo que
//  verá Claude» en un proyecto (Mac e iPhone/iPad; modelo en `SessionContextModel`). En los
//  servidores donde nadie lo activó ni lo apagó (el indicador es de antes de esta función)
//  enseña UNA vez, por servidor y dispositivo, el aviso «Nuevo» con un botón para activarlo.
//

import SwiftUI

struct SessionContextSettingsView: View {
    let model: SessionContextModel
    let projects: [Project]
    /// Identifica el servidor para recordar que ya se enseñó el aviso «Nuevo».
    let serverID: UUID

    @State private var projectPath: String = ""
    /// Servidores (uno por línea) en los que ya se enseñó el aviso.
    @AppStorage("sessionContextNoticeShown") private var noticeShown: String = ""
    /// El aviso se decide al abrir (y se queda durante esta visita aunque ya cuente como visto).
    @State private var showsNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsNotice && !model.isEnabled { newNotice }
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
        .task {
            await model.refresh()
            decideNotice()
        }
    }

    private func decideNotice() {
        let id = serverID.uuidString
        let shown = noticeShown.split(separator: "\n").contains { $0 == id }
        guard model.status?.isUndecided == true, !shown else { return }
        showsNotice = true
        noticeShown = (noticeShown.split(separator: "\n").map(String.init) + [id]).joined(separator: "\n")
    }

    private var newNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nuevo: contexto al arrancar Claude", systemImage: "sparkles")
                .font(.headline)
            Text("Argos puede darle a Claude, al abrirse en un proyecto, un resumen de lo que pasa ahí. En este servidor no está activado.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Activar") { Task { await model.setEnabled(true) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Al abrir Claude Code en un proyecto, Argos le da un resumen breve: el último CI de la rama, los cambios sin commit, los puertos abiertos, los encargos en cola, otros Claude en el mismo repositorio y lo que queda de tus límites.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Es un hook SessionStart en ~/.claude/settings.json (con copia en settings.json.argos-backup). Solo lee, tarda como mucho unos 3 segundos y solo da recuentos y nombres de rama: ni secretos ni textos del servidor.")
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
        case .ready(let status):
            Toggle("Contexto de Argos al arrancar Claude", isOn: toggleBinding(current: status.isEnabled))
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
