//
//  CheckpointsView.swift
//  ArgosiOS
//
//  «Puntos de restauración» en iPhone/iPad: activarlos en el proyecto; lista de turnos →
//  qué cambió en el turno (o hasta ahora) → diff de un archivo, con «Deshacer hasta aquí»
//  y «Restaurar este archivo». Mismo `CheckpointsModel` que el Mac. Confirmaciones en
//  `CheckpointsViewDialogs.swift`.
//

import SwiftUI

struct CheckpointsView: View {
    @State private var model: CheckpointsModel
    private let opensLatestTurn: Bool
    @State private var showsLatest = false

    init(path: String, viewModel: SessionsViewModel, opensLatestTurn: Bool = false) {
        _model = State(initialValue: CheckpointsModel(path: path, service: viewModel.service) { [weak viewModel] in
            viewModel?.claudeActivity(forProjectPath: path)
        })
        self.opensLatestTurn = opensLatestTurn
    }

    var body: some View {
        CheckpointsListContent(model: model)
            .navigationTitle("Puntos de restauración")
            .navigationBarTitleDisplayMode(.inline)
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
            .modifier(CheckpointDialogsiOS(model: model))
            .overlay(alignment: .bottom) { CheckpointNoticeiOS(model: model) }
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
            CheckpointSettingsSection(model: model, listing: listing)
            if listing.checkpoints.isEmpty {
                Section {
                    Text(CheckpointTexts.emptyDescription(listing)).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(listing.checkpoints) { checkpoint in
                        NavigationLink {
                            CheckpointDetailScreen(model: model, checkpoint: checkpoint)
                        } label: {
                            CheckpointRowiOS(checkpoint: checkpoint)
                        }
                    }
                } header: {
                    Text("Turnos")
                } footer: {
                    if let warning = CheckpointTexts.warning(listing) { Text(warning) }
                }
            }
            if listing.isEnabled { CheckpointMaintenanceSection(model: model) }
        }
    }
}

private struct CheckpointSettingsSection: View {
    let model: CheckpointsModel
    let listing: CheckpointListing

    var body: some View {
        Section {
            Toggle("Activados en este proyecto", isOn: enabledBinding)
            if listing.isEnabled {
                Toggle("Guardar un extracto de cada mensaje", isOn: promptsBinding)
            }
        } footer: {
            Text(listing.isEnabled ? CheckpointTexts.promptsFootnote : CheckpointTexts.enableFootnote)
        }
        .disabled(model.operation != nil)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.isEnabled }, set: { value in Task { await model.setEnabled(value) } })
    }

    private var promptsBinding: Binding<Bool> {
        Binding(get: { listing.storesPrompts }, set: { value in Task { await model.setStoresPrompts(value) } })
    }
}

private struct CheckpointMaintenanceSection: View {
    let model: CheckpointsModel
    @State private var confirmPurge = false
    @State private var confirmRemove = false

    var body: some View {
        Section {
            Button("Crear punto ahora") { Task { await model.createSnapshot() } }
            Button("Borrar todos los puntos…", role: .destructive) { confirmPurge = true }
            Button("Quitar el hook de este servidor…", role: .destructive) { confirmRemove = true }
        }
        .disabled(model.operation != nil)
        .confirmationDialog("¿Borrar todos los puntos de este proyecto?", isPresented: $confirmPurge,
                            titleVisibility: .visible) {
            Button("Borrar", role: .destructive) { Task { await model.purgeAll() } }
        } message: {
            Text("No se puede deshacer. Los archivos del proyecto no cambian.")
        }
        .confirmationDialog("¿Quitar el hook de captura del servidor?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Quitar", role: .destructive) { Task { await model.removeFromServer() } }
        } message: {
            Text("Se borran los puntos de este proyecto y ningún otro proyecto del servidor guardará puntos nuevos.")
        }
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
            } footer: {
                if let text = CheckpointTexts.skipsText(model.skipsInSelectedTurn) { Text(text) }
            }
            CheckpointFilesSection(model: model)
        }
        .navigationTitle(checkpoint.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: checkpoint.id) {
            if model.selectedID != checkpoint.id { await model.select(checkpoint.id) }
        }
    }

    private var comparisonBinding: Binding<CheckpointComparison> {
        Binding(get: { model.comparison }, set: { value in Task { await model.setComparison(value) } })
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

    var body: some View {
        Section {
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
                        CheckpointFileDiffScreen(model: model, file: file)
                    } label: {
                        CheckpointFileRowiOS(file: file)
                    }
                }
            }
        } header: {
            Text("Archivos")
        } footer: {
            if model.comparison == .turn { Text(CheckpointTexts.restoreFileOnlySinceThen) }
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
