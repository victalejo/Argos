//
//  ServerFormSheet.swift
//  Argos
//
//  Sheet para añadir o editar un servidor SSH. Recoge host/puerto/usuario, deja
//  elegir el archivo de clave privada (concede un security-scoped bookmark para
//  poder leerlo bajo App Sandbox) y la passphrase opcional (que se guarda en
//  Keychain, NUNCA en el modelo persistido ni en el código).
//

import AppKit
import SwiftUI

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
    @State private var authMethod: AuthMethod
    @State private var keyPath: String
    @State private var keyBookmark: Data?
    @State private var passphrase: String
    @State private var password: String
    @State private var bookmarkError: String?

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
            _authMethod = State(initialValue: .key)
            _keyPath = State(initialValue: "~/.ssh/id_ed25519")
            _keyBookmark = State(initialValue: nil)
            _passphrase = State(initialValue: "")
            _password = State(initialValue: "")
            editingID = nil
        case .edit(let server):
            _name = State(initialValue: server.name)
            _host = State(initialValue: server.host)
            _port = State(initialValue: String(server.port))
            _username = State(initialValue: server.username)
            _authMethod = State(initialValue: server.authMethod)
            _keyPath = State(initialValue: server.privateKeyPath)
            _keyBookmark = State(initialValue: server.privateKeyBookmark)
            _passphrase = State(initialValue: KeychainStore.passphrase(for: server.id) ?? "")
            _password = State(initialValue: KeychainStore.password(for: server.id) ?? "")
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

                Picker("Autenticación", selection: $authMethod) {
                    Text("Clave SSH").tag(AuthMethod.key)
                    Text("Contraseña").tag(AuthMethod.password)
                }
                .pickerStyle(.segmented)

                switch authMethod {
                case .key:
                    HStack {
                        TextField("Clave privada", text: $keyPath)
                        Button("Elegir…") { openKeyFilePicker() }
                    }
                    if let err = bookmarkError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    SecureField("Passphrase (opcional)", text: $passphrase)
                case .password:
                    SecureField("Contraseña", text: $password)
                }
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
    }

    private var canSave: Bool {
        let baseValid = !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
        switch authMethod {
        case .key:
            return baseValid && !keyPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .password:
            return baseValid && !password.isEmpty
        }
    }

    /// Abre NSOpenPanel (muestra archivos ocultos, empieza en ~/.ssh) y crea un
    /// security-scoped bookmark del archivo elegido para leerlo bajo App Sandbox.
    private func openKeyFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            keyPath = url.path
            bookmarkError = nil
            do {
                keyBookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                Log.store.info("Bookmark de clave SSH creado: \(url.path, privacy: .public)")
            } catch {
                keyBookmark = nil
                bookmarkError = "No se pudo crear el acceso al archivo: \(error.localizedDescription)"
                Log.store.error("Fallo al crear bookmark SSH: \(error)")
            }
        }
    }

    private func save() {
        guard canSave, let portValue = Int(port) else { return }

        let secret: String?
        let server: Server
        switch authMethod {
        case .key:
            let trimmedPass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            secret = trimmedPass.isEmpty ? nil : trimmedPass
            server = Server(
                id: editingID ?? UUID(),
                name: name.trimmingCharacters(in: .whitespaces),
                host: host.trimmingCharacters(in: .whitespaces),
                port: portValue,
                username: username.trimmingCharacters(in: .whitespaces),
                authMethod: .key,
                privateKeyPath: keyPath.trimmingCharacters(in: .whitespaces),
                privateKeyBookmark: keyBookmark,
                requiresPassphrase: !trimmedPass.isEmpty
            )
        case .password:
            secret = password.isEmpty ? nil : password
            server = Server(
                id: editingID ?? UUID(),
                name: name.trimmingCharacters(in: .whitespaces),
                host: host.trimmingCharacters(in: .whitespaces),
                port: portValue,
                username: username.trimmingCharacters(in: .whitespaces),
                authMethod: .password
            )
        }
        onSave(server, secret)
        dismiss()
    }
}
