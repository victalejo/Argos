//
//  ServerFormView.swift
//  ArgosiOS
//
//  Alta/edición de un servidor. Autenticación por contraseña o por clave Ed25519
//  importada desde Archivos (se guarda una copia privada; ver `ImportedKeyStore`).
//  Los secretos van al Keychain, nunca al JSON de servidores.
//

import SwiftUI
import UniformTypeIdentifiers

struct ServerFormView: View {
    enum Mode: Identifiable {
        case create
        case edit(Server)

        var id: String {
            switch self {
            case .create: return "nuevo"
            case .edit(let server): return server.id.uuidString
            }
        }
    }

    private enum TestState: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
    }

    let mode: Mode
    @Environment(ServerHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    @State private var serverID = UUID()
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var secret = ""
    @State private var requiresPassphrase = false
    @State private var keyPath = ""
    @State private var pendingKey: Data?
    @State private var isImportingKey = false
    @State private var testState: TestState = .idle
    @State private var errorMessage: String?

    private var isNew: Bool {
        if case .create = mode { return true }
        return false
    }

    private var hasKey: Bool { pendingKey != nil || !keyPath.isEmpty }

    /// Servidor tal como está guardado (para saber si cambió el método de acceso).
    private var original: Server? {
        if case .edit(let server) = mode { return server }
        return nil
    }

    /// Hace falta teclear el secreto si no hay uno guardado que sirva: alta, cambio de
    /// método, o passphrase recién activada.
    private var needsSecret: Bool {
        switch authMethod {
        case .password:
            return original?.authMethod != .password
        case .key:
            return requiresPassphrase && !(original?.authMethod == .key && original?.requiresPassphrase == true)
        }
    }

    private var canSave: Bool {
        let filled = ![name, host, username].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled, let portValue = Int(port), (1...65535).contains(portValue) else { return false }
        if needsSecret && secret.isEmpty { return false }
        return authMethod == .password || hasKey
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor") {
                    TextField("Nombre (p. ej. producción)", text: $name)
                    TextField("Host o IP", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Puerto", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Usuario", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Método", selection: $authMethod) {
                        Text("Contraseña").tag(AuthMethod.password)
                        Text("Clave SSH").tag(AuthMethod.key)
                    }
                    .pickerStyle(.segmented)

                    if authMethod == .password {
                        SecureField(needsSecret ? "Contraseña" : "Contraseña (vacía = sin cambios)", text: $secret)
                    } else {
                        Button {
                            isImportingKey = true
                        } label: {
                            Label(hasKey ? "Clave importada · cambiar" : "Importar clave privada…",
                                  systemImage: hasKey ? "key.fill" : "key")
                        }
                        Toggle("La clave tiene passphrase", isOn: $requiresPassphrase)
                        if requiresPassphrase {
                            SecureField(needsSecret ? "Passphrase" : "Passphrase (vacía = sin cambios)", text: $secret)
                        }
                    }
                } header: {
                    Text("Autenticación")
                } footer: {
                    Text(authMethod == .password
                         ? "La contraseña se guarda en el Llavero de este dispositivo."
                         : "Elige tu clave Ed25519 en formato OpenSSH (Archivos, iCloud Drive o AirDrop). Argos guarda una copia privada; la passphrase va al Llavero.")
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            Text("Probar conexión")
                            Spacer()
                            if testState == .testing { ProgressView() }
                        }
                    }
                    .disabled(!canSave || testState == .testing)
                    switch testState {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle(isNew ? "Nuevo servidor" : "Editar servidor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar", action: save).disabled(!canSave)
                }
            }
            .fileImporter(isPresented: $isImportingKey, allowedContentTypes: [.data, .text, .item]) { result in
                importKey(result)
            }
            .alert("No se pudo guardar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Acciones

    private func load() {
        guard case .edit(let server) = mode else { return }
        serverID = server.id
        name = server.name
        host = server.host
        port = String(server.port)
        username = server.username
        authMethod = server.authMethod
        requiresPassphrase = server.requiresPassphrase
        keyPath = server.privateKeyPath
    }

    private func importKey(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            _ = try ImportedKeyStore.validate(data)
            pendingKey = data
            testState = .idle
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Construye el servidor; si hay una clave nueva, la escribe en `keyDirectory`.
    private func buildServer(keyDirectory: URL) throws -> (Server, String?) {
        var path = keyPath
        if authMethod == .key, let pendingKey {
            path = try ImportedKeyStore.store(pendingKey, for: serverID, in: keyDirectory)
        }
        let server = Server(
            id: serverID,
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            privateKeyPath: authMethod == .key ? path : "",
            requiresPassphrase: authMethod == .key && requiresPassphrase
        )
        return (server, secret.isEmpty ? nil : secret)
    }

    private func save() {
        do {
            let (server, newSecret) = try buildServer(keyDirectory: ImportedKeyStore.defaultDirectory())
            // Editando sin teclear un secreto nuevo: se conserva el del Llavero.
            let secret = newSecret ?? (needsSecret ? nil : existingSecret(for: server))
            do {
                try hub.save(server, secret: secret, isNew: isNew)
            } catch {
                // No dejar en disco la clave de un servidor que no llegó a guardarse.
                if isNew, pendingKey != nil { ImportedKeyStore.remove(for: serverID) }
                throw error
            }
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func existingSecret(for server: Server) -> String? {
        server.authMethod == .password
            ? KeychainStore.password(for: server.id)
            : KeychainStore.passphrase(for: server.id)
    }

    /// Prueba con lo tecleado, sin guardar: la clave nueva se escribe en un directorio
    /// temporal que se borra al terminar.
    private func testConnection() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-test-\(UUID().uuidString)", isDirectory: true)
        let server: Server
        let secret: String?
        do {
            (server, secret) = try buildServer(keyDirectory: pendingKey == nil ? ImportedKeyStore.defaultDirectory() : scratch)
        } catch {
            testState = .failure(error.userMessage)
            return
        }
        let typed = secret ?? (needsSecret ? nil : existingSecret(for: server))
        // Una prueba no debe dejar confiada la huella (TOFU) de un servidor que quizá no
        // se guarde: si la registró ella, se olvida al terminar (salvo que ese host:puerto
        // ya esté guardado). La primera conexión real la vuelve a registrar.
        let wasTrusted = TOFUHostKeyValidator.isTrusted(host: server.host, port: server.port)
        testState = .testing
        Task {
            defer {
                try? FileManager.default.removeItem(at: scratch)
                if !wasTrusted, !hub.store.servers.contains(where: { $0.host == server.host && $0.port == server.port }) {
                    TOFUHostKeyValidator.forget(host: server.host, port: server.port)
                }
            }
            let config = server.authMethod == .key
                ? SSHService.Configuration(server: server, passphrase: typed)
                : SSHService.Configuration(server: server, password: typed)
            let service = SSHService(configuration: config)
            do {
                let who = try await service.testConnection()
                testState = .success(who.isEmpty ? "Conexión correcta." : "Conectado como «\(who)».")
            } catch {
                testState = .failure(error.userMessage)
            }
            await service.disconnect()
        }
    }
}
