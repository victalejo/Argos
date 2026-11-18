//
//  CheckpointsSheetDialogs.swift
//  Argos
//
//  Confirmaciones y avisos de la hoja «Puntos de restauración» (Mac): copia costosa,
//  «Deshacer hasta aquí» con la lista de archivos y los conflictos, «Restaurar este
//  archivo» y la confirmación extra si Claude está trabajando.
//

import SwiftUI

/// Alertas y hojas de la hoja de puntos.
struct CheckpointDialogs: ViewModifier {
    let model: CheckpointsModel

    func body(content: Content) -> some View {
        content
            .alert("No se pudo completar", isPresented: errorBinding) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("Guardar el estado actual costará", isPresented: heavyBinding) {
                Button("Continuar") {
                    guard let heavy = model.pendingHeavy else { return }
                    Task { await model.prepareRestore(heavy.checkpoint, force: true) }
                }
                Button("Cancelar", role: .cancel) { model.cancelHeavy() }
            } message: {
                Text(CheckpointTexts.heavyMessage(model.pendingHeavy?.reason ?? ""))
            }
            .sheet(isPresented: restoreBinding) {
                if let preview = model.pendingRestore {
                    CheckpointRestoreConfirmation(model: model, preview: preview)
                }
            }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var heavyBinding: Binding<Bool> {
        Binding(get: { model.pendingHeavy != nil }, set: { if !$0 { model.cancelHeavy() } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.cancelRestore() } })
    }
}

/// «Restaurar este archivo…» (solo en «Hasta ahora»), con su confirmación.
struct CheckpointRestoreFileButton: View {
    let model: CheckpointsModel
    let path: String
    @State private var confirm = false

    var body: some View {
        Button("Restaurar este archivo…") { confirm = true }
            .disabled(!model.canRestoreFile)
            .help("Lo deja como estaba en este punto (o lo borra si no existía)")
            .confirmationDialog(CheckpointTexts.restoreFileTitle(path), isPresented: $confirm) {
                Button(model.claudeIsWorking ? "Restaurar aunque Claude trabaja" : "Restaurar", role: .destructive) {
                    Task { await model.restoreFile(path, acknowledgingWork: true) }
                }
            } message: {
                Text(message)
            }
    }

    private var message: String {
        model.claudeIsWorking
            ? CheckpointTexts.workingWarning + " " + CheckpointTexts.restoreFileMessage
            : CheckpointTexts.restoreFileMessage
    }
}

struct CheckpointRestoreConfirmation: View {
    let model: CheckpointsModel
    let preview: CheckpointRestorePreview
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("¿Dejar los archivos como estaban en este punto?").font(.headline)
            Text(preview.checkpoint.title).foregroundStyle(.secondary).lineLimit(2)
            CheckpointRestoreWarnings(model: model, preview: preview, acknowledged: $acknowledged)
            List {
                CheckpointIssueSection(title: "No se puede restaurar", issues: preview.conflicts)
                CheckpointPathSection(title: "Se modificarán", paths: preview.toModify)
                CheckpointPathSection(title: "Se borrarán", paths: preview.toDelete)
                CheckpointPathSection(title: "Se recrearán", paths: preview.toRecreate)
                CheckpointPathSection(title: "Existen y git los ignora: no se tocan", paths: preview.untouched)
            }
            .frame(minHeight: 220)
            Text(CheckpointTexts.restoreFootnote).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { model.cancelRestore() }
                    .keyboardShortcut(.cancelAction)
                Button("Restaurar", role: .destructive) {
                    Task { await model.confirmRestore(acknowledgingWork: acknowledged) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private var canConfirm: Bool {
        preview.canRestore && (!model.claudeIsWorking || acknowledged)
    }
}

private struct CheckpointRestoreWarnings: View {
    let model: CheckpointsModel
    let preview: CheckpointRestorePreview
    @Binding var acknowledged: Bool

    var body: some View {
        if !preview.canRestore {
            Label(CheckpointTexts.conflictMessage(preview.conflicts), systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        }
        if let warning = CheckpointTexts.commitsWarning(preview) {
            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if model.claudeIsWorking {
            Label(CheckpointTexts.workingWarning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Toggle(CheckpointTexts.workingAcknowledgement, isOn: $acknowledged)
        }
    }
}

private struct CheckpointIssueSection: View {
    let title: String
    let issues: [CheckpointIssue]

    var body: some View {
        if !issues.isEmpty {
            Section("\(title) (\(issues.count))") {
                ForEach(issues.prefix(CheckpointTexts.maxListedPaths), id: \.self) { issue in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text(issue.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CheckpointPathSection: View {
    let title: String
    let paths: [String]

    var body: some View {
        if !paths.isEmpty {
            Section("\(title) (\(paths.count))") {
                ForEach(paths.prefix(CheckpointTexts.maxListedPaths), id: \.self) { path in
                    Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                if paths.count > CheckpointTexts.maxListedPaths {
                    Text("y \(paths.count - CheckpointTexts.maxListedPaths) más").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CheckpointNotice: View {
    let model: CheckpointsModel

    var body: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(5))
                    if model.notice == notice { model.notice = nil }
                }
        }
    }
}
