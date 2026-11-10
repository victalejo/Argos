//
//  ProjectFormSheet.swift
//  Argos
//
//  Formulario para crear, editar o "convertir en proyecto" una sesión suelta: nombre,
//  grupo, carpeta del servidor (con selector visual) y comando de arranque.
//

import SwiftUI

/// Qué formulario de proyecto abrir (y en qué servidor).
enum ProjectFormRequest: Identifiable {
    case new(Server)
    case edit(Server, Project)
    case convert(Server, TmuxSession)
    /// «Ramas en paralelo…» (worktrees) del repositorio del proyecto.
    case worktrees(Server, Project)

    var id: String {
        switch self {
        case .new(let server): return "new-\(server.id)"
        case .edit(_, let project): return "edit-\(project.id)"
        case .convert(let server, let session): return "convert-\(server.id)-\(session.name)"
        case .worktrees(_, let project): return "worktrees-\(project.id)"
        }
    }

    var server: Server {
        switch self {
        case .new(let server), .edit(let server, _), .convert(let server, _), .worktrees(let server, _): return server
        }
    }
}

struct ProjectFormSheet: View {
    let request: ProjectFormRequest
    let vm: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFocused: Bool
    @FocusState private var groupFocused: Bool
    @State private var settings = ProjectSettings.shared

    @State private var name = ""
    @State private var group = ""
    @State private var path = ""
    @State private var commandMode: CommandMode = .default
    @State private var customCommand = ""

    @State private var isPickingFolder = false
    /// Origen de un proyecto nuevo: una carpeta que ya existe o un repo de GitHub a clonar.
    @State private var source: Source = .folder
    @State private var clone: GitHubCloneModel
    /// Carpeta ya clonada: si después falla guardar el proyecto, reintentar no vuelve a clonar.
    @State private var clonedPath: String?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let projectID: UUID
    private let createdAt: Date
    /// Se conserva al editar (si no, se perdería la marca de "en el Mac").
    private var macCheckout: MacCheckout?

    enum Source: Hashable {
        case folder
        case clone
    }

    /// Comando de arranque elegido en el formulario.
    enum CommandMode: Hashable {
        case `default`
        case none
        case custom
    }

    init(request: ProjectFormRequest, vm: SessionsViewModel) {
        self.request = request
        self.vm = vm
        _clone = State(initialValue: GitHubCloneModel(service: vm.service))
        switch request {
        case .edit(_, let project):
            projectID = project.id
            createdAt = project.createdAt
            macCheckout = project.macCheckout
            _name = State(initialValue: project.name)
            _group = State(initialValue: project.group ?? "")
            _path = State(initialValue: project.path)
            switch project.startupCommand {
            case nil: _commandMode = State(initialValue: .default)
            case let command? where command.trimmingCharacters(in: .whitespaces).isEmpty:
                _commandMode = State(initialValue: .none)
            case let command?:
                _commandMode = State(initialValue: .custom)
                _customCommand = State(initialValue: command)
            }
        case .convert(_, let session):
            projectID = UUID()
            createdAt = Date()
            let (sessionGroup, short) = SessionGrouping.split(session.name)
            let hasGroup = short != session.name
            _name = State(initialValue: hasGroup ? short : session.name)
            _group = State(initialValue: hasGroup ? sessionGroup : "")
        case .new, .worktrees:
            projectID = UUID()
            createdAt = Date()
        }
    }

    private var title: String {
        switch request {
        case .new: return "Nuevo proyecto"
        case .edit: return "Editar proyecto"
        case .convert: return "Convertir en proyecto"
        case .worktrees: return "Ramas en paralelo"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArgosSheetHeader(
                title: title,
                subtitle: "Organiza tu trabajo en \(request.server.name).",
                symbol: "folder.badge.plus"
            )
            .padding(24)

            Divider()

            Form {
                Section {
                    TextField("Nombre", text: $name, prompt: Text("Nombre de tu proyecto"))
                        .focused($nameFocused)
                    groupField
                } header: {
                    Label("Identidad", systemImage: "square.stack.3d.up")
                } footer: {
                    Text("Opcional. Elige uno existente o escribe un nombre nuevo para crear el grupo.")
                        .font(.caption)
                }

                if case .new = request {
                    Section {
                        Picker("Origen", selection: $source) {
                            Text("Carpeta existente").tag(Source.folder)
                            Text("Clonar de GitHub").tag(Source.clone)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if source == .clone {
                    GitHubCloneFields(clone: clone, serverName: request.server.name) { isPickingFolder = true }
                } else {
                    Section {
                        folderField
                    } header: {
                        Label("Carpeta del servidor", systemImage: "folder")
                    } footer: {
                        Text("Elige una carpeta o escribe una ruta completa que empiece por /.")
                            .font(.caption)
                    }
                }

                Section {
                    commandField
                } header: {
                    Label("Al iniciar el proyecto", systemImage: "play.circle")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 280, idealHeight: formHeight, maxHeight: formHeight)
            .disabled(isSubmitting)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage {
                    ArgosFormNotice(message: errorMessage, symbol: "exclamationmark.circle.fill", tint: .red)
                }

                HStack(spacing: 10) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                        Text(clone.isCloning ? "Clonando \(clone.repository)…" : "Guardando proyecto…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSubmitting)
                    Button(submitLabel, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit)
                }
                .controlSize(.large)
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: commandMode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: source)
        // El nombre sigue a la carpeta clonada mientras el usuario no lo cambie.
        .onChange(of: clone.folder) { old, new in
            if name.isEmpty || name == old { name = new }
        }
        .onAppear { nameFocused = true }
        .task { await prefillFolderIfNeeded() }
        .sheet(isPresented: $isPickingFolder) {
            RemoteDirectoryPicker(
                service: vm.service,
                startPath: source == .clone ? clone.parent : (path.isEmpty ? "~" : path),
                onPick: { picked in
                    if source == .clone {
                        clone.parent = picked
                    } else {
                        path = picked
                        if name.isEmpty { name = (picked as NSString).lastPathComponent }
                    }
                    isPickingFolder = false
                },
                onCancel: { isPickingFolder = false }
            )
        }
    }

    private var submitLabel: String {
        if case .edit = request { return "Guardar" }
        return source == .clone ? "Clonar y crear" : "Crear proyecto"
    }

    private var formHeight: CGFloat {
        let base: CGFloat = source == .clone ? 520 : 380
        return base + (commandMode == .custom ? 35 : 0) + (isNew ? 50 : 0)
    }

    private var isNew: Bool {
        if case .new = request { return true }
        return false
    }

    // MARK: - Campos

    private var groupField: some View {
        HStack {
            TextField("Grupo", text: $group, prompt: Text("Sin grupo · escribe uno nuevo"))
                .focused($groupFocused)
            if isNewGroup {
                Text("Nuevo")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .help("Se creará el grupo «\(trimmedGroup)» al guardar")
            }
            Menu {
                Button {
                    group = ""
                    groupFocused = true
                } label: {
                    Label("Nuevo grupo…", systemImage: "plus")
                }
                let existing = existingGroups
                if !existing.isEmpty {
                    Divider()
                    ForEach(existing, id: \.self) { name in
                        Button(name) { group = name }
                    }
                }
                if !trimmedGroup.isEmpty {
                    Divider()
                    Button("Sin grupo") { group = "" }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Elegir un grupo existente o crear uno nuevo")
            .accessibilityLabel("Elegir o crear grupo")
        }
    }

    private var trimmedGroup: String { group.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// El nombre escrito no coincide con ningún grupo: se creará al guardar.
    private var isNewGroup: Bool { !trimmedGroup.isEmpty && !existingGroups.contains(trimmedGroup) }

    private var folderField: some View {
        HStack {
            TextField("Carpeta", text: $path, prompt: Text("/home/usuario/proyecto"))
                .font(.body.monospaced())
            Button("Explorar…") { isPickingFolder = true }
                .help("Explorar las carpetas de \(request.server.name)")
        }
    }

    @ViewBuilder
    private var commandField: some View {
        Picker("Al abrir", selection: $commandMode) {
            Text("Predeterminado (\(defaultCommandLabel))").tag(CommandMode.default)
            Text("No lanzar nada").tag(CommandMode.none)
            Text("Personalizado…").tag(CommandMode.custom)
        }
        if commandMode == .custom {
            TextField("Comando", text: $customCommand, prompt: Text("cc --continue, npm run dev…"))
                .font(.body.monospaced())
        }
    }

    private var defaultCommandLabel: String {
        settings.defaultStartupCommand.isEmpty ? "nada" : settings.defaultStartupCommand
    }

    private var existingGroups: [String] {
        Array(Set(vm.projects.compactMap(\.group))).sorted()
    }

    // MARK: - Envío

    private var canSubmit: Bool {
        !isSubmitting
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (source == .clone ? clone.canClone : path.trimmingCharacters(in: .whitespaces).hasPrefix("/"))
            && (commandMode != .custom || !customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var startupCommand: String? {
        switch commandMode {
        case .default: return nil
        case .none: return ""
        case .custom: return customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        let adopted: String? = if case .convert(_, let session) = request { session.name } else { nil }
        Task {
            do {
                // Al clonar, la carpeta del proyecto es la que acaba de crear `gh repo clone`.
                var folder = path
                if source == .clone {
                    if clonedPath == nil { clonedPath = try await clone.clone() }
                    folder = clonedPath ?? path
                }
                let project = Project(
                    id: projectID,
                    name: name,
                    group: group,
                    path: folder,
                    startupCommand: startupCommand,
                    createdAt: createdAt,
                    macCheckout: macCheckout
                )
                try await vm.saveProject(project, adoptingSession: adopted)
                dismiss()
            } catch {
                errorMessage = error.userMessage
                isSubmitting = false
            }
        }
    }

    /// Al convertir una sesión, propone la carpeta en la que está su primer panel.
    private func prefillFolderIfNeeded() async {
        guard case .convert(_, let session) = request, path.isEmpty else { return }
        if let found = try? await vm.service.sessionFirstPanePaths()[session.name] {
            path = found
        }
    }
}
