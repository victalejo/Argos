//
//  CheckpointsViewDialogs.swift
//  ArgosiOS
//
//  Diff de un archivo con «Restaurar», confirmación de «Deshacer hasta aquí» (archivos,
//  conflictos, Claude trabajando), aviso de copia costosa y avisos (iPhone/iPad).
//

import SwiftUI

struct CheckpointDialogsiOS: ViewModifier {
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
                    CheckpointRestoreSheet(model: model, preview: preview)
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

struct CheckpointFileDiffScreen: View {
    let model: CheckpointsModel
    let file: CheckpointFileChange
    @State private var confirm = false

    var body: some View {
        diffBody
            .navigationTitle(file.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if model.comparison == .sinceThen {
                        Button("Restaurar") { confirm = true }.disabled(!model.canRestoreFile)
                    }
                }
            }
            .confirmationDialog(CheckpointTexts.restoreFileTitle(file.path), isPresented: $confirm,
                                titleVisibility: .visible) {
                if !model.claudeIsWorking {
                    Button("Restaurar este archivo", role: .destructive) { Task { await model.restoreFile(file.path) } }
                } else if model.canStopClaude {
                    Button(CheckpointTexts.stopAndRestore, role: .destructive) {
                        Task { await model.stopClaudeAndRestore(file: file.path) }
                    }
                }
            } message: {
                Text(message)
            }
            .task(id: file.path) { await model.selectFile(file.path) }
    }

    private var message: String {
        model.claudeIsWorking
            ? CheckpointTexts.workingWarning + " " + CheckpointTexts.restoreFileMessage
            : CheckpointTexts.restoreFileMessage
    }

    @ViewBuilder
    private var diffBody: some View {
        switch model.diffState {
        case .loaded(let diff) where model.selectedFile == file.path:
            GitDiffView(diff: diff, fontSize: 11)
        case .failed(let message) where model.selectedFile == file.path:
            ContentUnavailableView("No se pudo leer el diff", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        default:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CheckpointRestoreSheet: View {
    let model: CheckpointsModel
    let preview: CheckpointRestorePreview

    var body: some View {
        NavigationStack {
            List {
                CheckpointRestoreHeaderSection(model: model, preview: preview)
                CheckpointIssueSectioniOS(title: "No se puede restaurar", issues: preview.conflicts)
                CheckpointPathSectioniOS(title: "Se modificarán", paths: preview.modifies)
                CheckpointPathSectioniOS(title: "Se borrarán", paths: preview.deletes)
                CheckpointPathSectioniOS(title: "Se recrearán", paths: preview.recreates)
                CheckpointPathSectioniOS(title: "No se tocan (ignorados o repositorios anidados)", paths: preview.untouched)
            }
            .navigationTitle("¿Deshacer hasta aquí?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { model.cancelRestore() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.claudeIsWorking {
                        Button("Detener y restaurar", role: .destructive) { Task { await model.stopClaudeAndRestore() } }
                            .disabled(!preview.canRestore || !model.canStopClaude)
                    } else {
                        Button("Restaurar", role: .destructive) { Task { await model.confirmRestore() } }
                            .disabled(!preview.canRestore)
                    }
                }
            }
        }
    }
}

private struct CheckpointRestoreHeaderSection: View {
    let model: CheckpointsModel
    let preview: CheckpointRestorePreview

    var body: some View {
        Section {
            Text(preview.checkpoint.title)
            if !preview.canRestore {
                Label(CheckpointTexts.conflictMessage(preview.conflicts), systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
            if let warning = CheckpointTexts.commitsWarning(preview) {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if model.claudeIsWorking {
                Label(CheckpointTexts.workingWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text(CheckpointTexts.restoreFootnote)
        }
    }
}

private struct CheckpointIssueSectioniOS: View {
    let title: String
    let issues: [CheckpointIssue]

    var body: some View {
        if !issues.isEmpty {
            Section("\(title) (\(issues.count))") {
                ForEach(issues.prefix(CheckpointTexts.maxListedPaths), id: \.self) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.path).font(.footnote.monospaced()).lineLimit(2).truncationMode(.middle)
                        Text(issue.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CheckpointPathSectioniOS: View {
    let title: String
    let paths: [String]

    var body: some View {
        if !paths.isEmpty {
            Section("\(title) (\(paths.count))") {
                ForEach(paths.prefix(CheckpointTexts.maxListedPaths), id: \.self) { path in
                    Text(path).font(.footnote.monospaced()).lineLimit(2).truncationMode(.middle)
                }
                if paths.count > CheckpointTexts.maxListedPaths {
                    Text("y \(paths.count - CheckpointTexts.maxListedPaths) más").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CheckpointNoticeiOS: View {
    let model: CheckpointsModel

    var body: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .lineLimit(3)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(5))
                    if model.notice == notice { model.notice = nil }
                }
        }
    }
}
