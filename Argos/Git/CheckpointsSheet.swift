//
//  CheckpointsSheet.swift
//  Argos
//
//  Hoja «Puntos de restauración» del panel «Cambios»: un punto por mensaje enviado a
//  Claude; a la izquierda los turnos, a la derecha qué cambió en el turno (o desde
//  entonces) con su diff, «Deshacer hasta aquí» y «Restaurar este archivo».
//

import SwiftUI

struct CheckpointsSheet: View {
    @State private var model: CheckpointsModel
    private let opensLatestTurn: Bool
    @Environment(\.dismiss) private var dismiss

    init(path: String, service: any SSHServicing, opensLatestTurn: Bool) {
        _model = State(initialValue: CheckpointsModel(path: path, service: service))
        self.opensLatestTurn = opensLatestTurn
    }

    var body: some View {
        VStack(spacing: 0) {
            CheckpointsToolbar(model: model) { dismiss() }
            Divider()
            CheckpointsContent(model: model)
        }
        .frame(minWidth: 880, idealWidth: 1040, minHeight: 560, idealHeight: 680)
        .task {
            if opensLatestTurn { await model.showLatestTurn() } else { await model.refresh() }
        }
        .alert("No se pudo completar", isPresented: errorBinding) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: restoreBinding) {
            if let preview = model.pendingRestore {
                CheckpointRestoreConfirmation(model: model, preview: preview)
            }
        }
        .overlay(alignment: .bottom) { CheckpointNotice(model: model) }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.cancelRestore() } })
    }
}

// MARK: - Barra superior

private struct CheckpointsToolbar: View {
    let model: CheckpointsModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tint)
            Text("Puntos de restauración").font(.headline)
            Spacer()
            if model.operation == .snapshot || model.operation == .toggle { ProgressView().controlSize(.small) }
            if model.listing != nil {
                Toggle("Crear puntos en este servidor", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .disabled(model.operation != nil)
                    .help("Afecta a todos los proyectos de este servidor y a todos tus dispositivos")
                Button("Crear punto ahora") { Task { await model.createSnapshot() } }
                    .disabled(model.operation != nil)
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Recargar")
                .accessibilityLabel("Recargar")
            Button("Cerrar", action: close).keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(12)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.isEnabledOnServer }, set: { value in Task { await model.setEnabledOnServer(value) } })
    }
}

// MARK: - Contenido

private struct CheckpointsContent: View {
    let model: CheckpointsModel

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Leyendo puntos de restauración…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gitMissing:
            ContentUnavailableView("git no está instalado", systemImage: "exclamationmark.triangle",
                                   description: Text("Instala git en el servidor para usar los puntos de restauración."))
        case .notRepository:
            ContentUnavailableView("No es un repositorio git", systemImage: "arrow.triangle.branch",
                                   description: Text("Los puntos de restauración necesitan que la carpeta esté bajo git."))
        case .failed(let message):
            ContentUnavailableView("No se pudieron leer", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let listing):
            if listing.checkpoints.isEmpty {
                CheckpointsEmptyView(listing: listing)
            } else {
                HSplitView {
                    CheckpointListView(model: model, listing: listing)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    CheckpointDetailView(model: model)
                        .frame(minWidth: 460, maxWidth: .infinity)
                }
            }
        }
    }
}

private struct CheckpointsEmptyView: View {
    let listing: CheckpointListing

    var body: some View {
        ContentUnavailableView {
            Label("Aún no hay puntos de restauración", systemImage: "clock.arrow.circlepath")
        } description: {
            Text(CheckpointTexts.emptyDescription(listing))
        }
    }
}

private struct CheckpointListView: View {
    let model: CheckpointsModel
    let listing: CheckpointListing

    var body: some View {
        VStack(spacing: 0) {
            if let warning = CheckpointTexts.warning(listing) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(8)
                Divider()
            }
            List(selection: selection) {
                ForEach(listing.checkpoints) { checkpoint in
                    CheckpointRow(checkpoint: checkpoint).tag(checkpoint.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedID }, set: { id in Task { await model.select(id) } })
    }
}

private struct CheckpointRow: View {
    let checkpoint: Checkpoint

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: CheckpointTexts.symbol(checkpoint.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkpoint.title).lineLimit(2)
                Text(CheckpointTexts.subtitle(checkpoint))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(checkpoint.title)
    }
}

// MARK: - Detalle

private struct CheckpointDetailView: View {
    let model: CheckpointsModel

    var body: some View {
        if let checkpoint = model.selected {
            VStack(spacing: 0) {
                CheckpointDetailHeader(model: model, checkpoint: checkpoint)
                Divider()
                HSplitView {
                    CheckpointFilesView(model: model)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    CheckpointDiffPane(model: model, checkpoint: checkpoint)
                        .frame(minWidth: 260, maxWidth: .infinity)
                }
            }
        } else {
            ContentUnavailableView("Elige un turno", systemImage: "list.bullet.rectangle",
                                   description: Text("Selecciona un punto para ver qué cambió en ese turno."))
        }
    }
}

private struct CheckpointDetailHeader: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(checkpoint.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                Text(checkpoint.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Comparar", selection: comparisonBinding) {
                ForEach(CheckpointComparison.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .help("«Este turno»: lo que cambió hasta el mensaje siguiente. «Hasta ahora»: lo que se desharía.")
            if model.operation == .preview || model.operation == .restore { ProgressView().controlSize(.small) }
            Button(role: .destructive) {
                Task { await model.prepareRestore(checkpoint) }
            } label: {
                Label("Deshacer hasta aquí…", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.operation != nil)
            .help("Deja los archivos como estaban justo antes de este mensaje (pide confirmación)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var comparisonBinding: Binding<CheckpointComparison> {
        Binding(get: { model.comparison }, set: { value in Task { await model.setComparison(value) } })
    }
}

private struct CheckpointFilesView: View {
    let model: CheckpointsModel

    var body: some View {
        switch model.files {
        case .none, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("No se pudo leer", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded(let files) where files.isEmpty:
            ContentUnavailableView("Sin cambios", systemImage: "checkmark.circle",
                                   description: Text("No cambió ningún archivo."))
        case .loaded(let files):
            List(selection: selection) {
                Section("\(files.count) archivo\(files.count == 1 ? "" : "s")") {
                    ForEach(files) { file in
                        CheckpointFileRow(file: file).tag(file.path)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedFile }, set: { path in Task { await model.selectFile(path) } })
    }
}

private struct CheckpointFileRow: View {
    let file: CheckpointFileChange

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName).lineLimit(1).truncationMode(.middle)
                    .strikethrough(file.kind == .deleted)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            GitChangeBadge(kind: file.gitKind)
        }
        .help(file.path)
    }
}

private struct CheckpointDiffPane: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint
    @State private var confirmFile = false

    var body: some View {
        if let path = model.selectedFile {
            VStack(spacing: 0) {
                header(path)
                Divider()
                diffBody
            }
        } else {
            ContentUnavailableView("Elige un archivo", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Selecciona un archivo para ver su diff."))
        }
    }

    private func header(_ path: String) -> some View {
        HStack(spacing: 8) {
            Text(path).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
            Spacer()
            if case .loaded(let diff) = model.diffState { GitDiffStat(diff: diff) }
            if model.operation == .restoreFile(path) { ProgressView().controlSize(.small) }
            Button("Restaurar este archivo…") { confirmFile = true }
                .disabled(model.operation != nil)
                .help("Lo deja como estaba en este punto (o lo borra si no existía)")
                .confirmationDialog(CheckpointTexts.restoreFileTitle(path), isPresented: $confirmFile) {
                    Button("Restaurar", role: .destructive) {
                        Task { await model.restoreFile(path, from: checkpoint) }
                    }
                } message: {
                    Text(CheckpointTexts.restoreFileMessage)
                }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var diffBody: some View {
        switch model.diffState {
        case .none, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("No se pudo leer el diff", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let diff):
            GitDiffView(diff: diff).background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - Confirmación y avisos

private struct CheckpointRestoreConfirmation: View {
    let model: CheckpointsModel
    let preview: CheckpointRestorePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("¿Dejar los archivos como estaban en este punto?").font(.headline)
            Text(preview.checkpoint.title).foregroundStyle(.secondary).lineLimit(2)
            if let warning = CheckpointTexts.commitsWarning(preview) {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            List {
                CheckpointPathSection(title: "Se modificarán", paths: preview.toModify)
                CheckpointPathSection(title: "Se borrarán", paths: preview.toDelete)
                CheckpointPathSection(title: "Se recrearán", paths: preview.toRecreate)
            }
            .frame(minHeight: 220)
            Text(CheckpointTexts.restoreFootnote).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { model.cancelRestore() }
                    .keyboardShortcut(.cancelAction)
                Button("Restaurar", role: .destructive) { Task { await model.confirmRestore() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
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

private struct CheckpointNotice: View {
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
