//
//  ProjectFormView.swift
//  ArgosiOS
//
//  Crear, editar o «convertir en proyecto» una sesión suelta desde el iPhone/iPad (el del
//  Mac es `ProjectFormSheet`): nombre, grupo, carpeta del servidor —una existente o un
//  repositorio de GitHub que clona el `gh` del servidor— y comando de arranque. Los
//  proyectos viven en el servidor, así que el Mac los ve igual.
//

import SwiftUI

/// Qué formulario de proyecto abrir.
enum ProjectFormMode: Identifiable {
    case new
    case edit(Project)
    case convert(TmuxSession)

    var id: String {
        switch self {
        case .new: return "nuevo"
        case .edit(let project): return "editar-\(project.id)"
        case .convert(let session): return "convertir-\(session.name)"
        }
    }
}

struct ProjectFormView: View {
    let mode: ProjectFormMode
    let vm: SessionsViewModel
    let serverName: String

    @Environment(\.dismiss) private var dismiss
    @State private var settings = ProjectSettings.shared

    @State private var name = ""
    @State private var group = ""
    @State private var path = ""
    @State private var commandMode: CommandMode = .default
    @State private var customCommand = ""
    @State private var source: Source = .folder
    @State private var clone: GitHubCloneModel
    /// Carpeta ya clonada: si después falla guardar el proyecto, reintentar no vuelve a clonar.
    @State private var clonedPath: String?
    @State private var pickingFolder = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let projectID: UUID
    private let createdAt: Date
    /// Se conserva al editar (si no, se perdería la marca de «en el Mac»).
    private let macCheckout: MacCheckout?

    enum Source: Hashable { case folder, clone }
    enum CommandMode: Hashable { case `default`, none, custom }

    init(mode: ProjectFormMode, vm: SessionsViewModel, serverName: String) {
        self.mode = mode
        self.vm = vm
        self.serverName = serverName
        _clone = State(initialValue: GitHubCloneModel(service: vm.service))
        switch mode {
        case .edit(let project):
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
        case .convert(let session):
            projectID = UUID()
            createdAt = Date()
            macCheckout = nil
            let (sessionGroup, short) = SessionGrouping.split(session.name)
            let hasGroup = short != session.name
            _name = State(initialValue: hasGroup ? short : session.name)
            _group = State(initialValue: hasGroup ? sessionGroup : "")
        case .new:
            projectID = UUID()
            createdAt = Date()
            macCheckout = nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                if case .new = mode {
                    Section {
                        Picker("Origen", selection: $source) {
                            Text("Carpeta").tag(Source.folder)
                            Text("Clonar de GitHub").tag(Source.clone)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if source == .clone {
                    GitHubCloneFields(clone: clone, serverName: serverName) { pickingFolder = true }
                } else {
                    folderSection
                }
                commandSection
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            .disabled(isSubmitting)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }.disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button(submitLabel, action: submit).disabled(!canSubmit)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSubmitting {
                    Label(clone.isCloning ? "Clonando \(clone.repository)…" : "Guardando proyecto…", systemImage: "hourglass")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .navigationDestination(isPresented: $pickingFolder) {
                RemoteFolderPicker(
                    service: vm.service,
                    startPath: source == .clone ? clone.parent : (path.isEmpty ? "~" : path)
                ) { picked in
                    if source == .clone {
                        clone.parent = picked
                    } else {
                        path = picked
                        if name.isEmpty { name = (picked as NSString).lastPathComponent }
                    }
                    pickingFolder = false
                }
            }
            // El nombre sigue a la carpeta clonada mientras el usuario no lo cambie.
            .onChange(of: clone.folder) { old, new in
                if name.isEmpty || name == old { name = new }
            }
            .task { await prefillFolderIfNeeded() }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var title: String {
        switch mode {
        case .new: return "Nuevo proyecto"
        case .edit: return "Editar proyecto"
        case .convert: return "Convertir en proyecto"
        }
    }

    private var submitLabel: String {
        if case .edit = mode { return "Guardar" }
        return source == .clone ? "Clonar" : "Crear"
    }

    // MARK: - Secciones

    private var identitySection: some View {
        Section {
            TextField("Nombre", text: $name, prompt: Text("Nombre de tu proyecto"))
            HStack {
                TextField("Grupo", text: $group, prompt: Text("Sin grupo"))
                if !existingGroups.isEmpty {
                    Menu {
                        ForEach(existingGroups, id: \.self) { name in
                            Button(name) { group = name }
                        }
                        if !trimmedGroup.isEmpty {
                            Divider()
                            Button("Sin grupo") { group = "" }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .accessibilityLabel("Elegir un grupo existente")
                }
            }
        } header: {
            Text("Identidad")
        } footer: {
            if !trimmedGroup.isEmpty && !existingGroups.contains(trimmedGroup) {
                Text("Se creará el grupo «\(trimmedGroup)» al guardar.")
            }
        }
    }

    private var folderSection: some View {
        Section {
            TextField("Carpeta", text: $path, prompt: Text("/home/usuario/proyecto"))
                .font(.body.monospaced())
                .plainCodeInput()
            Button("Explorar carpetas de \(serverName)…", systemImage: "folder") { pickingFolder = true }
        } header: {
            Text("Carpeta del servidor")
        } footer: {
            Text("Elige una carpeta o escribe una ruta completa que empiece por /.")
        }
    }

    @ViewBuilder
    private var commandSection: some View {
        Section("Al iniciar el proyecto") {
            Picker("Al abrir", selection: $commandMode) {
                Text("Predeterminado (\(settings.defaultStartupCommand.isEmpty ? "nada" : settings.defaultStartupCommand))")
                    .tag(CommandMode.default)
                Text("No lanzar nada").tag(CommandMode.none)
                Text("Personalizado…").tag(CommandMode.custom)
            }
            if commandMode == .custom {
                TextField("Comando", text: $customCommand, prompt: Text("cc --continue, npm run dev…"))
                    .font(.body.monospaced())
                    .plainCodeInput()
            }
        }
    }

    private var trimmedGroup: String { group.trimmingCharacters(in: .whitespacesAndNewlines) }

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
        let adopted: String? = if case .convert(let session) = mode { session.name } else { nil }
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
        guard case .convert(let session) = mode, path.isEmpty else { return }
        if let found = try? await vm.service.sessionFirstPanePaths()[session.name] {
            path = found
        }
    }
}
