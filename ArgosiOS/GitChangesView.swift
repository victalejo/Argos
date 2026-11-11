//
//  GitChangesView.swift
//  ArgosiOS
//
//  Pestaña «Cambios» de un proyecto en iPhone/iPad: rama con pull/push, archivos
//  cambiados (toca para ver el diff, desliza para descartar, marca cuáles entran) y el
//  commit al final. Mismo `GitChangesModel` que el Mac.
//

import SwiftUI

struct GitChangesView: View {
    @State private var model: GitChangesModel
    private let viewModel: SessionsViewModel

    /// `viewModel`: el del servidor, para vigilar el CI de lo que se sube y avisar al terminar.
    init(viewModel: SessionsViewModel, path: String) {
        self.viewModel = viewModel
        _model = State(initialValue: GitChangesModel(path: path, service: viewModel.service) { [weak viewModel] root in
            viewModel?.watchCI(root: root)
        })
    }

    var body: some View {
        content
            .task {
                await model.refresh()
                await model.pollWhileVisible()
            }
            .refreshable { await model.refresh() }
            .alert("No se pudo completar", isPresented: errorBinding) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .overlay(alignment: .bottom) { notice }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Leyendo cambios…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gitMissing:
            ContentUnavailableView("git no está instalado", systemImage: "exclamationmark.triangle",
                                   description: Text("Instala git en el servidor para ver los cambios."))
        case .notRepository:
            ContentUnavailableView {
                Label("No es un repositorio git", systemImage: "arrow.triangle.branch")
            } description: {
                Text("Ejecuta «git init» en el terminal para empezar a seguir sus cambios.")
            } actions: {
                Button("Volver a comprobar") { Task { await model.refresh() } }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudieron leer los cambios", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") { Task { await model.refresh() } }
            }
        case .loaded(let status):
            GitChangesList(model: model, status: status, viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let text = model.notice {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    if model.notice == text { model.notice = nil }
                }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct GitChangesList: View {
    @Bindable var model: GitChangesModel
    let status: GitRepositoryStatus
    let viewModel: SessionsViewModel
    @State private var pendingDiscard: GitFileChange?

    var body: some View {
        List {
            branchSection
            Section("GitHub") {
                GitHubStatusHost(root: status.root, branch: status.branch, service: viewModel.service) { [weak viewModel] root, sha in
                    viewModel?.watchCI(root: root, sha: sha)
                }
                .id(status.root)
            }
            if status.isClean {
                Section {
                    Label("Sin cambios desde el último commit", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                changesSection
                commitSection
            }
        }
        .confirmationDialog(
            pendingDiscard.map { "¿Descartar los cambios de «\($0.fileName)»?" } ?? "",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible
        ) {
            if let change = pendingDiscard {
                Button(change.isUntracked ? "Eliminar archivo" : "Descartar", role: .destructive) {
                    Task { await model.discard(change) }
                }
            }
        } message: {
            Text("No se puede deshacer.")
        }
    }

    private var branchSection: some View {
        Section {
            HStack {
                Label(status.branch.name ?? "HEAD desacoplado", systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                Spacer()
                Text(trackingText).font(.caption).foregroundStyle(.secondary)
            }
            if model.canPull || model.canPush || model.operation == .pull || model.operation == .push {
                HStack {
                    Button { Task { await model.pull() } } label: {
                        Label("Pull", systemImage: "arrow.down")
                    }
                    .disabled(!model.canPull)
                    Spacer()
                    if model.operation == .pull || model.operation == .push { ProgressView() }
                    Spacer()
                    Button { Task { await model.push() } } label: {
                        Label(status.branch.upstream == nil ? "Publicar" : "Push", systemImage: "arrow.up")
                    }
                    .disabled(!model.canPush)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var changesSection: some View {
        Section {
            ForEach(status.changes) { change in
                NavigationLink {
                    GitFileDiffScreen(model: model, change: change)
                } label: {
                    GitChangeRowiOS(model: model, change: change)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { pendingDiscard = change } label: {
                        Label("Descartar", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            if status.truncated {
                Text("Hay más archivos que no se muestran.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("\(status.changes.count) archivo\(status.changes.count == 1 ? "" : "s")")
                Spacer()
                Button(model.includedCount == status.changes.count ? "Ninguno" : "Todos") {
                    model.setAllIncluded(model.includedCount != status.changes.count)
                }
                .font(.caption)
                .textCase(nil)
            }
        }
    }

    private var commitSection: some View {
        Section {
            TextField("Mensaje del commit", text: $model.commitMessage, axis: .vertical)
                .lineLimit(2...5)
            Button {
                Task { await model.suggestCommitMessage() }
            } label: {
                HStack {
                    Label("Sugerir mensaje con Claude", systemImage: "sparkles")
                    if model.operation == .suggest {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!model.canSuggestMessage)
            Button {
                Task { await model.commit() }
            } label: {
                HStack {
                    Text("Commit de \(model.includedCount) archivo\(model.includedCount == 1 ? "" : "s")")
                    Spacer()
                    if model.operation == .commit { ProgressView() }
                }
            }
            .disabled(!model.canCommit)
        } footer: {
            if model.hasConflicts { Text("Resuelve los conflictos antes de hacer commit.") }
        }
    }

    private var trackingText: String {
        let branch = status.branch
        if !branch.hasCommits { return "sin commits" }
        guard branch.upstream != nil else { return "sin rama remota" }
        if branch.upstreamGone { return "remota borrada" }
        if branch.ahead == 0 && branch.behind == 0 { return "al día" }
        return [branch.ahead > 0 ? "↑\(branch.ahead)" : nil, branch.behind > 0 ? "↓\(branch.behind)" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}

private struct GitChangeRowiOS: View {
    let model: GitChangesModel
    let change: GitFileChange

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.setIncluded(!model.isIncluded(change), for: change)
            } label: {
                Image(systemName: model.isIncluded(change) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(model.isIncluded(change) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.isIncluded(change) ? "Quitar del commit" : "Incluir en el commit")
            VStack(alignment: .leading, spacing: 2) {
                Text(change.fileName).lineLimit(1).truncationMode(.middle)
                    .strikethrough(change.kind == .deleted)
                if !change.directory.isEmpty || change.originalPath != nil {
                    Text(change.originalPath.map { "← \($0)" } ?? change.directory)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if model.operation == .discard(change.path) { ProgressView() }
            GitChangeBadge(kind: change.kind)
        }
    }
}

private struct GitFileDiffScreen: View {
    let model: GitChangesModel
    let change: GitFileChange

    var body: some View {
        Group {
            switch model.diffState {
            case .loaded(let diff) where model.selectedPath == change.path:
                GitDiffView(diff: diff, fontSize: 11)
            case .failed(let message) where model.selectedPath == change.path:
                ContentUnavailableView("No se pudo leer el diff", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(change.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if case .loaded(let diff) = model.diffState, model.selectedPath == change.path {
                    GitDiffStat(diff: diff)
                }
            }
        }
        .task { await model.select(change.path) }
    }
}
