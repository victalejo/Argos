//
//  WorktreesView.swift
//  ArgosiOS
//
//  «Ramas en paralelo» de un proyecto en el iPhone/iPad (en el Mac, `WorktreesSheet`):
//  los worktrees de su repositorio —cada uno, una carpeta con su rama y su proyecto con su
//  agente— y el alta de uno nuevo. La lógica es la misma (`WorktreesModel`).
//

import SwiftUI

struct WorktreesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorktreesModel
    @State private var settings = ProjectSettings.shared
    @State private var pendingRemoval: GitWorktree?

    init(project: Project, vm: SessionsViewModel) {
        _model = State(initialValue: WorktreesModel(parent: project, viewModel: vm))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Ramas en paralelo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isWorking {
                            ProgressView()
                        } else if case .loaded = model.state {
                            Button("Crear") {
                                model.errorMessage = nil
                                Task { await model.create(defaultStartupCommand: settings.defaultStartupCommand) }
                            }
                            .disabled(!model.canCreate)
                        }
                    }
                }
                .task { await model.load() }
                .refreshable { await model.load() }
                .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible, presenting: pendingRemoval) { worktree in
                    Button((worktree.changedCount ?? 0) > 0 ? "Quitar y perder los cambios" : "Quitar", role: .destructive) {
                        Task { await model.remove(worktree, force: (worktree.changedCount ?? 0) > 0) }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: { worktree in
                    Text(removalMessage(worktree))
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Leyendo worktrees…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gitMissing:
            ContentUnavailableView("git no está instalado", systemImage: "exclamationmark.triangle",
                                   description: Text("Instala git en el servidor para usar ramas en paralelo."))
        case .notRepository:
            ContentUnavailableView("No es un repositorio git", systemImage: "arrow.triangle.branch",
                                   description: Text("La carpeta del proyecto no está bajo git."))
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudieron leer los worktrees", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") { Task { await model.load() } }
            }
        case .loaded(let listing):
            Form {
                if let error = model.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
                } else if let notice = model.notice {
                    Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Section {
                    ForEach(listing.worktrees) { worktree in row(worktree) }
                } header: {
                    Text("Worktrees del repositorio")
                } footer: {
                    Text("Cada rama en su carpeta, con su propio agente. Desliza para quitar una.")
                }
                newBranchSection
            }
            .disabled(model.isWorking)
        }
    }

    // MARK: - Lista

    private func row(_ worktree: GitWorktree) -> some View {
        let project = model.project(for: worktree)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: worktree.isMain ? "folder.fill" : "arrow.triangle.branch")
                    .foregroundStyle(worktree.isMain ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(worktree.displayBranch).font(.body.weight(.medium)).lineLimit(1)
                if worktree.isMain { tag("principal", .accentColor) }
                if model.isRunning(worktree) { tag("en marcha", .green) }
                if let changed = worktree.changedCount, changed > 0 { tag("✎\(changed)", .orange) }
                if worktree.isPrunable { tag("carpeta perdida", .red) }
            }
            Text(project.map { "\($0.name) · \(worktree.path)" } ?? worktree.path)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if project == nil, !worktree.isMain, worktree.branch != nil {
                Button("Añadir como proyecto") { Task { await model.adopt(worktree) } }
                    .font(.callout)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            if !worktree.isMain && !worktree.isLocked {
                Button("Quitar", systemImage: "trash", role: .destructive) { pendingRemoval = worktree }
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Rama nueva

    @ViewBuilder
    private var newBranchSection: some View {
        Section {
            Picker("Rama", selection: $model.createsBranch) {
                Text("Nueva").tag(true)
                Text("Existente").tag(false)
            }
            .pickerStyle(.segmented)
            if model.createsBranch {
                TextField("Nombre", text: $model.branch, prompt: Text("feat/login"))
                    .font(.body.monospaced())
                    .plainCodeInput()
                Picker("Desde", selection: $model.base) {
                    ForEach(model.baseOptions, id: \.self) { option in
                        Text(option == "HEAD" ? "La rama actual (HEAD)" : option).tag(option)
                    }
                }
            } else if model.freeBranches.isEmpty {
                Text("Todas las ramas locales ya están abiertas en algún worktree.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Rama", selection: $model.branch) {
                    ForEach(model.freeBranches, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Carpeta", text: $model.path, prompt: Text("/ruta/app-worktrees/rama"))
                .font(.body.monospaced())
                .plainCodeInput()
            Toggle("Arrancar el agente al crearla", isOn: $model.startsAgent)
        } header: {
            Text("Nueva rama en paralelo")
        } footer: {
            if !model.branch.isEmpty, let error = model.validationError {
                Text(error).foregroundStyle(.red)
            } else if !model.branch.isEmpty {
                Text("Se creará el proyecto «\(model.projectName)»\(model.namingParent.group.map { " en el grupo \($0)" } ?? "").")
            }
        }
    }

    // MARK: - Quitar

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var removalTitle: String {
        pendingRemoval.map { "¿Quitar el worktree de \($0.displayBranch)?" } ?? ""
    }

    private func removalMessage(_ worktree: GitWorktree) -> String {
        var parts = ["Se borra su carpeta del servidor y su proyecto de Argos; si su sesión corre, se detiene. "
                     + "La rama y sus commits se conservan."]
        if let changed = worktree.changedCount, changed > 0 {
            parts.append("Tiene \(changed) archivo\(changed == 1 ? "" : "s") sin confirmar que se perderán.")
        }
        return parts.joined(separator: "\n\n")
    }
}
