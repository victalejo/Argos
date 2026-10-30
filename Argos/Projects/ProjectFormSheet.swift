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

    var id: String {
        switch self {
        case .new(let server): return "new-\(server.id)"
        case .edit(_, let project): return "edit-\(project.id)"
        case .convert(let server, let session): return "convert-\(server.id)-\(session.name)"
        }
    }

    var server: Server {
        switch self {
        case .new(let server), .edit(let server, _), .convert(let server, _): return server
        }
    }
}

struct ProjectFormSheet: View {
    let request: ProjectFormRequest
    let vm: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var settings = ProjectSettings.shared

    @State private var name = ""
    @State private var group = ""
    @State private var path = ""
    @State private var commandMode: CommandMode = .default
    @State private var customCommand = ""

    @State private var isPickingFolder = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let projectID: UUID
    private let createdAt: Date
    /// Se conserva al editar (si no, se perdería la marca de "en el Mac").
    private var macCheckout: MacCheckout?

    /// Comando de arranque elegido en el formulario.
    enum CommandMode: Hashable {
        case `default`
        case none
        case custom
    }

    init(request: ProjectFormRequest, vm: SessionsViewModel) {
        self.request = request
        self.vm = vm
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
        case .new:
            projectID = UUID()
            createdAt = Date()
        }
    }

    private var title: String {
        switch request {
        case .new: return "Nuevo proyecto"
        case .edit: return "Editar proyecto"
        case .convert: return "Convertir en proyecto"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))

            Form {
                TextField("Nombre", text: $name, prompt: Text("coro"))
                groupField
                folderField
                commandField
            }
            .formStyle(.grouped)
            .disabled(isSubmitting)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isSubmitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitLabel, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await prefillFolderIfNeeded() }
        .sheet(isPresented: $isPickingFolder) {
            RemoteDirectoryPicker(
                service: vm.service,
                startPath: path.isEmpty ? "~" : path,
                onPick: { picked in
                    path = picked
                    if name.isEmpty { name = (picked as NSString).lastPathComponent }
                    isPickingFolder = false
                },
                onCancel: { isPickingFolder = false }
            )
        }
    }

    private var submitLabel: String {
        if case .edit = request { return "Guardar" }
        return "Crear proyecto"
    }

    // MARK: - Campos

    private var groupField: some View {
        HStack {
            TextField("Grupo", text: $group, prompt: Text("opcional, p. ej. ia portafolio"))
            let existing = existingGroups
            if !existing.isEmpty {
                Menu {
                    ForEach(existing, id: \.self) { name in
                        Button(name) { group = name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Elegir un grupo existente")
            }
        }
    }

    private var folderField: some View {
        HStack {
            TextField("Carpeta", text: $path, prompt: Text("/home/usuario/proyecto"))
                .font(.body.monospaced())
            Button("Elegir…") { isPickingFolder = true }
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
            && path.trimmingCharacters(in: .whitespaces).hasPrefix("/")
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
        let project = Project(
            id: projectID,
            name: name,
            group: group,
            path: path,
            startupCommand: startupCommand,
            createdAt: createdAt,
            macCheckout: macCheckout
        )
        let adopted: String? = if case .convert(_, let session) = request { session.name } else { nil }
        Task {
            do {
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
