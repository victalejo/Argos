//
//  GitChangesPanelView.swift
//  Argos
//
//  Pestaña «Cambios» de un proyecto: qué archivos cambió el agente (git status), el
//  diff del seleccionado y, abajo, el commit de los marcados; arriba, la rama y
//  pull/push. Se refresca solo cada pocos segundos mientras está visible.
//

import SwiftUI

struct GitChangesPanelView: View {
    @State private var model: GitChangesModel
    private let viewModel: SessionsViewModel

    /// `viewModel`: el del servidor, para vigilar el CI de lo que se sube y avisar al terminar.
    init(path: String, viewModel: SessionsViewModel) {
        self.viewModel = viewModel
        _model = State(initialValue: GitChangesModel(path: path, service: viewModel.service) { [weak viewModel] root in
            viewModel?.watchCI(root: root)
        })
    }

    var body: some View {
        content
            // Ocupa todo el detalle: si no, con poco contenido (p. ej. «Sin cambios») el
            // panel se centra y deja franjas vacías arriba y abajo.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                await model.refresh()
                await model.pollWhileVisible()
            }
            .alert("No se pudo completar", isPresented: errorBinding) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Leyendo cambios…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gitMissing:
            ContentUnavailableView("git no está instalado", systemImage: "exclamationmark.triangle",
                                   description: Text("Instala git en el servidor para ver los cambios."))
        case .notRepository:
            ContentUnavailableView {
                Label("No es un repositorio git", systemImage: "arrow.triangle.branch")
            } description: {
                Text("La carpeta del proyecto no está bajo git. Ejecuta «git init» en el terminal para empezar a seguir sus cambios.")
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
            HSplitView {
                GitChangesSidebar(model: model, status: status, viewModel: viewModel)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 460, maxHeight: .infinity)
                GitDiffPane(model: model)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { GitNoticeBanner(model: model) }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

// MARK: - Columna izquierda

private struct GitChangesSidebar: View {
    let model: GitChangesModel
    let status: GitRepositoryStatus
    let viewModel: SessionsViewModel

    var body: some View {
        VStack(spacing: 0) {
            GitBranchHeader(model: model, status: status)
            GitHubStatusHost(root: status.root, branch: status.branch, service: viewModel.service) { [weak viewModel] root, sha in
                viewModel?.watchCI(root: root, sha: sha)
            }
            .id(status.root)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()
            if status.isClean {
                ContentUnavailableView("Sin cambios", systemImage: "checkmark.circle",
                                       description: Text("El árbol de trabajo coincide con el último commit."))
                    .frame(maxHeight: .infinity)
            } else {
                list
                Divider()
                GitCommitBox(model: model)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var list: some View {
        List(selection: Binding(
            get: { model.selectedPath },
            set: { path in Task { await model.select(path) } }
        )) {
            Section {
                ForEach(status.changes) { change in
                    GitChangeRow(model: model, change: change)
                        .tag(change.path)
                }
                if status.truncated {
                    Text("Hay más archivos que no se muestran.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("\(status.changes.count) archivo\(status.changes.count == 1 ? "" : "s")")
                    Spacer()
                    Button(model.includedCount == status.changes.count ? "Desmarcar todo" : "Marcar todo") {
                        model.setAllIncluded(model.includedCount != status.changes.count)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct GitBranchHeader: View {
    let model: GitChangesModel
    let status: GitRepositoryStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.branch.name ?? "HEAD desacoplado")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(trackingText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(status.root)
            Spacer(minLength: 4)
            if model.operation == .pull || model.operation == .push {
                ProgressView().controlSize(.small)
            }
            Button { Task { await model.pull() } } label: {
                Label("Pull", systemImage: "arrow.down")
                    .labelStyle(.iconOnly)
            }
            .disabled(!model.canPull)
            .help(status.branch.behind > 0 ? "Traer \(status.branch.behind) commit(s) (solo avance rápido)" : "Traer cambios del remoto (solo avance rápido)")
            .accessibilityLabel("Pull")
            Button { Task { await model.push() } } label: {
                Label(status.branch.ahead > 0 ? "\(status.branch.ahead)" : "Push", systemImage: "arrow.up")
            }
            .disabled(!model.canPush)
            .help(status.branch.upstream == nil ? "Publicar la rama en origin" : "Subir los commits al remoto")
            .accessibilityLabel(status.branch.upstream == nil ? "Publicar rama" : "Push")
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Recargar cambios")
            .accessibilityLabel("Recargar cambios")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var trackingText: String {
        let branch = status.branch
        if !branch.hasCommits { return "Sin commits todavía" }
        guard let upstream = branch.upstream else { return "\(status.repositoryName) · sin rama remota" }
        if branch.upstreamGone { return "\(upstream) ya no existe" }
        var parts = [upstream]
        if branch.ahead > 0 { parts.append("↑\(branch.ahead)") }
        if branch.behind > 0 { parts.append("↓\(branch.behind)") }
        if branch.ahead == 0 && branch.behind == 0 { parts.append("al día") }
        return parts.joined(separator: " · ")
    }
}

private struct GitChangeRow: View {
    let model: GitChangesModel
    let change: GitFileChange
    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: 7) {
            Toggle("", isOn: Binding(
                get: { model.isIncluded(change) },
                set: { model.setIncluded($0, for: change) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Incluir \(change.fileName) en el commit")
            FileIconView(name: change.fileName)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.fileName)
                    .lineLimit(1).truncationMode(.middle)
                    .strikethrough(change.kind == .deleted)
                if !change.directory.isEmpty || change.originalPath != nil {
                    Text(change.originalPath.map { "← \($0)" } ?? change.directory)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if model.operation == .discard(change.path) {
                ProgressView().controlSize(.mini)
            }
            GitChangeBadge(kind: change.kind)
        }
        .help(change.path)
        .contextMenu {
            Button("Descartar cambios…", role: .destructive) { confirmDiscard = true }
                .disabled(model.operation != nil)
            Button("Copiar ruta") { copy(change.path) }
        }
        .confirmationDialog(discardTitle, isPresented: $confirmDiscard) {
            Button(change.isUntracked ? "Eliminar archivo" : "Descartar", role: .destructive) {
                Task { await model.discard(change) }
            }
        } message: {
            Text("No se puede deshacer.")
        }
    }

    private var discardTitle: String {
        change.isUntracked
            ? "¿Eliminar «\(change.fileName)»? Es un archivo nuevo sin seguimiento."
            : "¿Descartar los cambios de «\(change.fileName)» y dejarlo como en el último commit?"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Icono por tipo de archivo (reutiliza el del explorador).
private struct FileIconView: View {
    let name: String

    var body: some View {
        let icon = FileIcon.file(named: name)
        Image(systemName: icon.symbol)
            .foregroundStyle(icon.tint.color)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

private struct GitCommitBox: View {
    @Bindable var model: GitChangesModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.commitMessage)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(height: 64)
                    .accessibilityLabel("Mensaje del commit")
                if model.commitMessage.isEmpty {
                    Text("Mensaje del commit (p. ej. «fix: …»)")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(.leading, 5).padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if model.hasConflicts {
                    Label("Resuelve los conflictos primero", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if model.operation == .commit || model.operation == .suggest { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.suggestCommitMessage() }
                } label: {
                    Label("Sugerir", systemImage: "sparkles")
                }
                .disabled(!model.canSuggestMessage)
                .help("Claude Code, en el servidor, propone el mensaje a partir de los cambios marcados y del estilo de los commits recientes")
                Button {
                    Task { await model.commit() }
                } label: {
                    Text("Commit (\(model.includedCount))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Hace commit de los archivos marcados (⌘↩)")
            }
        }
        .padding(10)
    }
}

// MARK: - Diff

private struct GitDiffPane: View {
    let model: GitChangesModel
    @State private var confirmDiscard = false

    var body: some View {
        if let change = model.selectedChange {
            VStack(spacing: 0) {
                header(change)
                Divider()
                diffBody
            }
        } else {
            ContentUnavailableView("Elige un archivo", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Selecciona un archivo de la lista para ver qué cambió."))
        }
    }

    private func header(_ change: GitFileChange) -> some View {
        HStack(spacing: 8) {
            GitChangeBadge(kind: change.kind)
            Text(change.path)
                .font(.callout.weight(.medium))
                .lineLimit(1).truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            if case .loaded(let diff) = model.diffState { GitDiffStat(diff: diff) }
            Button(role: .destructive) { confirmDiscard = true } label: {
                Label("Descartar", systemImage: "arrow.uturn.backward")
            }
            .controlSize(.small)
            .disabled(model.operation != nil)
            .help(change.isUntracked ? "Eliminar este archivo nuevo" : "Dejarlo como en el último commit")
            .confirmationDialog("¿Descartar los cambios de «\(change.fileName)»?", isPresented: $confirmDiscard) {
                Button(change.isUntracked ? "Eliminar archivo" : "Descartar", role: .destructive) {
                    Task { await model.discard(change) }
                }
            } message: {
                Text("No se puede deshacer.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
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
            GitDiffView(diff: diff)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct GitNoticeBanner: View {
    let model: GitChangesModel

    var body: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    if model.notice == notice { model.notice = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
