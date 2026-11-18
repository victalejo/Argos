//
//  CheckpointsView.swift
//  ArgosiOS
//
//  «Puntos de restauración» en iPhone/iPad: un punto por mensaje enviado a Claude. Lista
//  de turnos → qué cambió en el turno (o hasta ahora) → diff de un archivo, con «Deshacer
//  hasta aquí» y «Restaurar este archivo». Mismo `CheckpointsModel` que el Mac.
//

import SwiftUI

struct CheckpointsView: View {
    @State private var model: CheckpointsModel
    private let opensLatestTurn: Bool
    @State private var showsLatest = false

    init(path: String, service: any SSHServicing, opensLatestTurn: Bool = false) {
        _model = State(initialValue: CheckpointsModel(path: path, service: service))
        self.opensLatestTurn = opensLatestTurn
    }

    var body: some View {
        CheckpointsListContent(model: model)
            .navigationTitle("Puntos de restauración")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Crear punto") { Task { await model.createSnapshot() } }
                        .disabled(model.operation != nil || model.listing == nil)
                }
            }
            .task {
                guard opensLatestTurn else { await model.refresh(); return }
                await model.showLatestTurn()
                showsLatest = model.selected != nil
            }
            .refreshable { await model.refresh() }
            .navigationDestination(isPresented: $showsLatest) {
                if let checkpoint = model.checkpoints.first {
                    CheckpointDetailScreen(model: model, checkpoint: checkpoint)
                }
            }
            .alert("No se pudo completar", isPresented: errorBinding) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .overlay(alignment: .bottom) { CheckpointNoticeiOS(model: model) }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct CheckpointsListContent: View {
    let model: CheckpointsModel

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Leyendo puntos…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gitMissing:
            ContentUnavailableView("git no está instalado", systemImage: "exclamationmark.triangle")
        case .notRepository:
            ContentUnavailableView("No es un repositorio git", systemImage: "arrow.triangle.branch",
                                   description: Text("Los puntos de restauración necesitan git."))
        case .failed(let message):
            ContentUnavailableView("No se pudieron leer", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let listing):
            CheckpointsList(model: model, listing: listing)
        }
    }
}

private struct CheckpointsList: View {
    let model: CheckpointsModel
    let listing: CheckpointListing

    var body: some View {
        List {
            Section {
                Toggle("Crear puntos en este servidor", isOn: enabledBinding)
                    .disabled(model.operation != nil)
            } footer: {
                Text(CheckpointTexts.warning(listing) ?? "Uno cada vez que envías un mensaje a Claude Code.")
            }
            if listing.checkpoints.isEmpty {
                Section {
                    Text(CheckpointTexts.emptyDescription(listing)).foregroundStyle(.secondary)
                }
            } else {
                Section("Turnos") {
                    ForEach(listing.checkpoints) { checkpoint in
                        NavigationLink {
                            CheckpointDetailScreen(model: model, checkpoint: checkpoint)
                        } label: {
                            CheckpointRowiOS(checkpoint: checkpoint)
                        }
                    }
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.isEnabledOnServer }, set: { value in Task { await model.setEnabledOnServer(value) } })
    }
}

private struct CheckpointRowiOS: View {
    let checkpoint: Checkpoint

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(checkpoint.title).lineLimit(2)
                Text(CheckpointTexts.subtitle(checkpoint)).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: CheckpointTexts.symbol(checkpoint.kind))
        }
    }
}

// MARK: - Detalle de un turno

private struct CheckpointDetailScreen: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint

    var body: some View {
        List {
            Section {
                Picker("Comparar", selection: comparisonBinding) {
                    ForEach(CheckpointComparison.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                CheckpointRestoreButton(model: model, checkpoint: checkpoint)
            } header: {
                Text(checkpoint.date.formatted(date: .abbreviated, time: .shortened))
            }
            CheckpointFilesSection(model: model, checkpoint: checkpoint)
        }
        .navigationTitle(checkpoint.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: checkpoint.id) {
            if model.selectedID != checkpoint.id { await model.select(checkpoint.id) }
        }
        .sheet(isPresented: restoreBinding) {
            if let preview = model.pendingRestore {
                CheckpointRestoreSheet(model: model, preview: preview)
            }
        }
    }

    private var comparisonBinding: Binding<CheckpointComparison> {
        Binding(get: { model.comparison }, set: { value in Task { await model.setComparison(value) } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.cancelRestore() } })
    }
}

private struct CheckpointRestoreButton: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint

    var body: some View {
        Button(role: .destructive) {
            Task { await model.prepareRestore(checkpoint) }
        } label: {
            HStack {
                Label("Deshacer hasta aquí…", systemImage: "arrow.uturn.backward")
                if model.operation == .preview || model.operation == .restore {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(model.operation != nil)
    }
}

private struct CheckpointFilesSection: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint

    var body: some View {
        Section("Archivos") {
            switch model.files {
            case .none, .loading:
                ProgressView()
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            case .loaded(let files) where files.isEmpty:
                Text("No cambió ningún archivo.").foregroundStyle(.secondary)
            case .loaded(let files):
                ForEach(files) { file in
                    NavigationLink {
                        CheckpointFileDiffScreen(model: model, checkpoint: checkpoint, file: file)
                    } label: {
                        CheckpointFileRowiOS(file: file)
                    }
                }
            }
        }
    }
}

private struct CheckpointFileRowiOS: View {
    let file: CheckpointFileChange

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
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
    }
}

private struct CheckpointFileDiffScreen: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint
    let file: CheckpointFileChange
    @State private var confirm = false

    var body: some View {
        diffBody
            .navigationTitle(file.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Restaurar") { confirm = true }
                        .disabled(model.operation != nil)
                }
            }
            .confirmationDialog(CheckpointTexts.restoreFileTitle(file.path), isPresented: $confirm,
                                titleVisibility: .visible) {
                Button("Restaurar este archivo", role: .destructive) {
                    Task { await model.restoreFile(file.path, from: checkpoint) }
                }
            } message: {
                Text(CheckpointTexts.restoreFileMessage)
            }
            .task(id: file.path) { await model.selectFile(file.path) }
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

// MARK: - Confirmación y avisos

private struct CheckpointRestoreSheet: View {
    let model: CheckpointsModel
    let preview: CheckpointRestorePreview

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(preview.checkpoint.title)
                    if let warning = CheckpointTexts.commitsWarning(preview) {
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } footer: {
                    Text(CheckpointTexts.restoreFootnote)
                }
                CheckpointPathSectioniOS(title: "Se modificarán", paths: preview.toModify)
                CheckpointPathSectioniOS(title: "Se borrarán", paths: preview.toDelete)
                CheckpointPathSectioniOS(title: "Se recrearán", paths: preview.toRecreate)
            }
            .navigationTitle("¿Deshacer hasta aquí?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { model.cancelRestore() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restaurar", role: .destructive) { Task { await model.confirmRestore() } }
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

private struct CheckpointNoticeiOS: View {
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
