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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, host, port, username, key, passphrase, password }

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
    @State private var testState: TestState = .idle

    private let editingID: UUID?

    /// Resultado de "Probar conexión".
    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

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
        VStack(alignment: .leading, spacing: 0) {
            ArgosSheetHeader(
                title: mode.title,
                subtitle: "Tu espacio de trabajo empieza con una conexión SSH.",
                symbol: "server.rack"
            )
            .padding(24)

            Divider()

            Form {
                Section {
                    TextField("Nombre", text: $name, prompt: Text("Desarrollo, Producción…"))
                        .focused($focusedField, equals: .name)
                    TextField("Host", text: $host, prompt: Text("192.168.1.10 o ejemplo.com"))
                        .focused($focusedField, equals: .host)
                    TextField("Puerto", text: $port, prompt: Text("22"))
                        .focused($focusedField, equals: .port)
                    TextField("Usuario", text: $username, prompt: Text("usuario SSH"))
                        .focused($focusedField, equals: .username)
                } header: {
                    Label("Conexión", systemImage: "network")
                }

                Section {
                    Picker("Autenticación", selection: $authMethod) {
                        Text("Clave SSH").tag(AuthMethod.key)
                        Text("Contraseña").tag(AuthMethod.password)
                    }
                    .pickerStyle(.segmented)

                    switch authMethod {
                    case .key:
                        HStack {
                            TextField("Clave privada", text: $keyPath)
                                .focused($focusedField, equals: .key)
                            Button("Elegir archivo…") { openKeyFilePicker() }
                                .help("Selecciona tu clave privada SSH para autorizar el acceso al archivo")
                        }
                        if let err = bookmarkError {
                            Label(err, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        SecureField("Passphrase (opcional)", text: $passphrase)
                            .focused($focusedField, equals: .passphrase)
                    case .password:
                        SecureField("Contraseña", text: $password)
                            .focused($focusedField, equals: .password)
                    }
                } header: {
                    Label("Acceso seguro", systemImage: "lock.shield")
                } footer: {
                    Text("Tus credenciales se guardan de forma segura en el Llavero de macOS.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 280, idealHeight: authMethod == .key ? 415 : 365,
                   maxHeight: authMethod == .key ? 415 : 365)
            .disabled(testState == .testing)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                testResultView

                HStack(spacing: 10) {
                    Button(action: testConnection) {
                        if testState == .testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Probando…")
                            }
                        } else {
                            Label("Probar conexión", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(!canSave || testState == .testing)
                    .help("Comprueba el acceso con estos datos antes de guardar")

                    Spacer()
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(mode.actionLabel, action: save)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave || testState == .testing)
                }
                .controlSize(.large)
            }
            .padding(.top, 12)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: authMethod)
        .onAppear { focusedField = .name }
        // Un cambio en los datos de conexión invalida el resultado anterior del test.
        .onChange(of: connectionFingerprint) { _, _ in
            if testState != .testing { testState = .idle }
        }
    }

    /// Resultado de "Probar conexión" (oculto en estado inicial).
    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .success(let message):
            ArgosFormNotice(message: message, symbol: "checkmark.circle.fill", tint: .green)
        case .failure(let message):
            ArgosFormNotice(message: message, symbol: "exclamationmark.circle.fill", tint: .red)
        }
    }

    /// Huella de los campos que afectan a la conexión: al cambiar cualquiera, el
    /// resultado del test deja de ser válido.
    private var connectionFingerprint: String {
        "\(host)|\(port)|\(username)|\(authMethod.rawValue)|\(keyPath)|\(passphrase)|\(password)|\(keyBookmark?.count ?? 0)"
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

    /// Construye el `Server` y el secreto (passphrase/contraseña) a partir del estado
    /// actual del formulario. Lo comparten `save()` y `testConnection()`.
    private func buildServerAndSecret(portValue: Int) -> (server: Server, secret: String?) {
        switch authMethod {
        case .key:
            let trimmedPass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = Server(
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
            return (server, trimmedPass.isEmpty ? nil : trimmedPass)
        case .password:
            let server = Server(
                id: editingID ?? UUID(),
                name: name.trimmingCharacters(in: .whitespaces),
                host: host.trimmingCharacters(in: .whitespaces),
                port: portValue,
                username: username.trimmingCharacters(in: .whitespaces),
                authMethod: .password
            )
            return (server, password.isEmpty ? nil : password)
        }
    }

    private func save() {
        guard canSave, let portValue = Int(port) else { return }
        let (server, secret) = buildServerAndSecret(portValue: portValue)
        onSave(server, secret)
        dismiss()
    }

    /// Prueba la conexión SSH con los datos del formulario (sin guardar): conecta,
    /// autentica y ejecuta `whoami`. Usa el secreto TECLEADO en el formulario, no el de
    /// Keychain, para validar lo que el usuario está a punto de guardar.
    private func testConnection() {
        guard canSave, let portValue = Int(port) else { return }
        let (server, secret) = buildServerAndSecret(portValue: portValue)
        testState = .testing
        Task {
            let config: SSHService.Configuration = server.authMethod == .key
                ? SSHService.Configuration(server: server, passphrase: secret)
                : SSHService.Configuration(server: server, password: secret)
            let service = SSHService(configuration: config)
            do {
                let who = try await service.testConnection()
                await service.disconnect()
                testState = .success(who.isEmpty ? "Conexión correcta." : "Conectado como “\(who)”.")
            } catch {
                await service.disconnect()
                testState = .failure(error.userMessage)
            }
        }
    }
}

/// Shared visual language for the creation sheets; native controls retain keyboard behavior.
struct ArgosSheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 50, height: 50)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ArgosFormNotice: View {
    let message: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
