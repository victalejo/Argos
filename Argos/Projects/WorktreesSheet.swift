//
//  WorktreesSheet.swift
//  Argos
//
//  «Ramas en paralelo» de un proyecto: los worktrees de su repositorio (cada uno, una
//  carpeta con su rama y, en Argos, su proyecto con su agente) y el alta de uno nuevo.
//  Varios agentes trabajan a la vez en ramas distintas sin pisarse los archivos.
//

import SwiftUI

struct WorktreesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorktreesModel
    @State private var settings = ProjectSettings.shared
    @State private var pendingRemoval: GitWorktree?

    init(project: Project, vm: SessionsViewModel) {
        _model = State(initialValue: WorktreesModel(parent: project, viewModel: vm))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArgosSheetHeader(
                title: "Ramas en paralelo",
                subtitle: "Cada rama en su carpeta, con su propio agente. Basado en git worktree.",
                symbol: "arrow.triangle.branch"
            )
            .padding(24)
            Divider()
            content
                .frame(minHeight: 300, idealHeight: 470, maxHeight: 560)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.load() }
        .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible, presenting: pendingRemoval) { worktree in
            Button((worktree.changedCount ?? 0) > 0 ? "Quitar y perder los cambios" : "Quitar", role: .destructive) {
                Task { await model.remove(worktree, force: (worktree.changedCount ?? 0) > 0) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { worktree in
            Text(removalMessage(worktree))
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
                Section("Worktrees del repositorio") {
                    ForEach(listing.worktrees) { worktree in row(worktree) }
                }
                newBranchSection(listing)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.isWorking)
        }
    }

    // MARK: - Lista

    private func row(_ worktree: GitWorktree) -> some View {
        let project = model.project(for: worktree)
        return HStack(spacing: 10) {
            Image(systemName: worktree.isMain ? "folder.fill" : "arrow.triangle.branch")
                .foregroundStyle(worktree.isMain ? Color.accentColor : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(worktree.displayBranch).font(.body.weight(.medium)).lineLimit(1)
                    if worktree.isMain { tag("principal", .accentColor) }
                    if model.isRunning(worktree) { tag("en marcha", .green) }
                    if let changed = worktree.changedCount, changed > 0 { tag("✎\(changed)", .orange) }
                    if worktree.isPrunable { tag("carpeta perdida", .red) }
                }
                Text(project.map { "\($0.name) · \(worktree.path)" } ?? worktree.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(worktree.path)
            }
            Spacer(minLength: 6)
            if project == nil, !worktree.isMain, worktree.branch != nil {
                Button("Añadir como proyecto") { Task { await model.adopt(worktree) } }
                    .help("Ya existía (creado fuera de Argos): añádelo a tus proyectos")
            }
            if !worktree.isMain {
                Button(role: .destructive) { pendingRemoval = worktree } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Quitar este worktree (la rama se conserva)")
                .accessibilityLabel("Quitar el worktree de \(worktree.displayBranch)")
                .disabled(worktree.isLocked)
            }
        }
        .padding(.vertical, 2)
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
    private func newBranchSection(_ listing: GitWorktreeListing) -> some View {
        Section {
            Picker("Rama", selection: $model.createsBranch) {
                Text("Nueva").tag(true)
                Text("Existente").tag(false)
            }
            .pickerStyle(.segmented)
            if model.createsBranch {
                TextField("Nombre", text: $model.branch, prompt: Text("feat/login"))
                    .font(.body.monospaced())
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
            Toggle("Arrancar el agente al crearla", isOn: $model.startsAgent)
        } header: {
            Text("Nueva rama en paralelo")
        } footer: {
            if !model.branch.isEmpty, let error = model.validationError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if !model.branch.isEmpty {
                Text("Se creará el proyecto «\(model.projectName)»\(model.namingParent.group.map { " en el grupo \($0)" } ?? "").")
                    .font(.caption)
            }
        }
    }

    // MARK: - Pie

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.errorMessage {
                ArgosFormNotice(message: error, symbol: "exclamationmark.circle.fill", tint: .red)
            } else if let notice = model.notice {
                ArgosFormNotice(message: notice, symbol: "checkmark.circle.fill", tint: .green)
            }
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cerrar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Crear rama") {
                    model.errorMessage = nil
                    Task { await model.create(defaultStartupCommand: settings.defaultStartupCommand) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCreate)
            }
            .controlSize(.large)
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
