//
//  CheckpointsSheet.swift
//  Argos
//
//  Hoja «Puntos de restauración» del panel «Cambios»: activarlos en el proyecto; a la
//  izquierda los turnos, a la derecha qué cambió en el turno (o desde entonces) con su
//  diff, «Deshacer hasta aquí» y «Restaurar este archivo». Confirmación y avisos en
//  `CheckpointsSheetDialogs.swift`.
//

import SwiftUI

struct CheckpointsSheet: View {
    @State private var model: CheckpointsModel
    private let opensLatestTurn: Bool
    @Environment(\.dismiss) private var dismiss

    init(path: String, viewModel: SessionsViewModel, opensLatestTurn: Bool) {
        _model = State(initialValue: CheckpointsModel(
            path: path, service: viewModel.service,
            activity: { [weak viewModel] in viewModel?.claudeActivity(forProjectPath: path) },
            stopClaude: { [weak viewModel] in try await viewModel?.interruptClaude(forProjectPath: path) }
        ))
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
        .modifier(CheckpointDialogs(model: model))
        .overlay(alignment: .bottom) { CheckpointNotice(model: model) }
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
            if model.operation == .snapshot || model.operation == .settings { ProgressView().controlSize(.small) }
            if model.listing != nil {
                Toggle("Activados en este proyecto", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .disabled(model.operation != nil)
                    .help(CheckpointTexts.enableFootnote)
                CheckpointsMoreMenu(model: model)
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
        Binding(get: { model.isEnabled }, set: { value in Task { await model.setEnabled(value) } })
    }
}

private struct CheckpointsMoreMenu: View {
    let model: CheckpointsModel
    @State private var confirmPurge = false
    @State private var confirmRemove = false

    var body: some View {
        Menu {
            Button("Crear punto ahora") { Task { await model.createSnapshot() } }
                .disabled(!model.isEnabled)
            Toggle("Guardar un extracto de cada mensaje", isOn: promptsBinding)
                .disabled(!model.isEnabled)
            Divider()
            Button("Borrar todos los puntos…", role: .destructive) { confirmPurge = true }
            Button("Quitar el hook de este servidor…", role: .destructive) { confirmRemove = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.operation != nil)
        .help("Más opciones")
        .confirmationDialog("¿Borrar todos los puntos de este proyecto?", isPresented: $confirmPurge) {
            Button("Borrar", role: .destructive) { Task { await model.purgeAll() } }
        } message: {
            Text("No se puede deshacer. Los archivos del proyecto no cambian.")
        }
        .confirmationDialog("¿Quitar el hook de captura del servidor?", isPresented: $confirmRemove) {
            Button("Quitar", role: .destructive) { Task { await model.removeFromServer() } }
        } message: {
            Text("Se desactiva y se borran los puntos de este proyecto, y ningún otro proyecto de este servidor guardará puntos nuevos.")
        }
    }

    private var promptsBinding: Binding<Bool> {
        Binding(get: { model.listing?.storesPrompts ?? false },
                set: { value in Task { await model.setStoresPrompts(value) } })
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
        case .loaded(let listing) where listing.checkpoints.isEmpty:
            CheckpointsEmptyView(model: model, listing: listing)
        case .loaded(let listing):
            HSplitView {
                CheckpointListView(model: model, listing: listing)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                CheckpointDetailView(model: model)
                    .frame(minWidth: 460, maxWidth: .infinity)
            }
        }
    }
}

private struct CheckpointsEmptyView: View {
    let model: CheckpointsModel
    let listing: CheckpointListing

    var body: some View {
        ContentUnavailableView {
            Label("Aún no hay puntos de restauración", systemImage: "clock.arrow.circlepath")
        } description: {
            Text(CheckpointTexts.emptyDescription(listing))
        } actions: {
            if listing.isEnabled {
                Button("Crear punto ahora") { Task { await model.createSnapshot() } }
            } else {
                Button("Activar en este proyecto") { Task { await model.setEnabled(true) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(model.operation != nil)
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
                if let text = CheckpointTexts.skipsText(model.skipsInSelectedTurn) {
                    Label(text, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                Divider()
                HSplitView {
                    CheckpointFilesView(model: model)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    CheckpointDiffPane(model: model)
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
                Section("\(files.count) archivos") {
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

    var body: some View {
        if let path = model.selectedFile {
            VStack(spacing: 0) {
                CheckpointDiffHeader(model: model, path: path)
                Divider()
                diffBody
            }
        } else {
            ContentUnavailableView("Elige un archivo", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Selecciona un archivo para ver su diff."))
        }
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

private struct CheckpointDiffHeader: View {
    let model: CheckpointsModel
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Text(path).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
            Spacer()
            if case .loaded(let diff) = model.diffState { GitDiffStat(diff: diff) }
            if model.operation == .restoreFile(path) { ProgressView().controlSize(.small) }
            if model.comparison == .sinceThen {
                CheckpointRestoreFileButton(model: model, path: path)
            } else {
                Text(CheckpointTexts.restoreFileOnlySinceThen)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
