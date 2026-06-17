//
//  ServerFormSheet.swift
//  Argos
//
//  Sheet para añadir o editar un servidor SSH. Recoge host/puerto/usuario, deja
//  elegir el archivo de clave privada (concede un security-scoped bookmark para
//  poder leerlo bajo App Sandbox) y la passphrase opcional (que se guarda en
//  Keychain, NUNCA en el modelo persistido ni en el código).
//

import SwiftUI
import UniformTypeIdentifiers

struct ServerFormSheet: View {

    enum Mode: Equatable {
        case add
        case edit(Server)

        var title: String {
            switch self {
            case .add: return "Nuevo servidor"
            case .edit: return "Editar servidor"
            }
        }
        var actionLabel: String {
            switch self {
            case .add: return "Añadir"
            case .edit: return "Guardar"
            }
        }
    }

    let mode: Mode
    /// Devuelve el servidor resultante y la passphrase a guardar en Keychain
    /// (`nil` = sin passphrase). El llamador persiste ambos.
    let onSave: (Server, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var keyPath: String
    @State private var keyBookmark: Data?
    @State private var passphrase: String
    @State private var isShowingKeyPicker = false

    private let editingID: UUID?

    init(mode: Mode, onSave: @escaping (Server, String?) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _host = State(initialValue: "")
            _port = State(initialValue: "22")
            _username = State(initialValue: "")
            _keyPath = State(initialValue: "~/.ssh/id_ed25519")
            _keyBookmark = State(initialValue: nil)
            _passphrase = State(initialValue: "")
            editingID = nil
        case .edit(let server):
            _name = State(initialValue: server.name)
            _host = State(initialValue: server.host)
            _port = State(initialValue: String(server.port))
            _username = State(initialValue: server.username)
            _keyPath = State(initialValue: server.privateKeyPath)
            _keyBookmark = State(initialValue: server.privateKeyBookmark)
            _passphrase = State(initialValue: KeychainStore.passphrase(for: server.id) ?? "")
            editingID = server.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title).font(.title2.weight(.semibold))

            Form {
                TextField("Nombre", text: $name, prompt: Text("dev"))
                TextField("Host", text: $host, prompt: Text("192.168.1.10 o ejemplo.com"))
                TextField("Puerto", text: $port, prompt: Text("22"))
                TextField("Usuario", text: $username, prompt: Text("usuario"))

                HStack {
                    TextField("Clave privada", text: $keyPath)
                    Button("Elegir…") { isShowingKeyPicker = true }
                }
                SecureField("Passphrase (opcional)", text: $passphrase)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.actionLabel, action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fileImporter(
            isPresented: $isShowingKeyPicker,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            handleKeySelection(result)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
            && !keyPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Crea un security-scoped bookmark del archivo elegido para poder leerlo
    /// luego bajo App Sandbox.
    private func handleKeySelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        keyPath = url.path
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        keyBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func save() {
        guard canSave, let portValue = Int(port) else { return }
        let trimmedPass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = Server(
            id: editingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue,
            username: username.trimmingCharacters(in: .whitespaces),
            privateKeyPath: keyPath.trimmingCharacters(in: .whitespaces),
            privateKeyBookmark: keyBookmark,
            requiresPassphrase: !trimmedPass.isEmpty
        )
        onSave(server, trimmedPass.isEmpty ? nil : trimmedPass)
        dismiss()
    }
}
