//
//  ServerKeySection.swift
//  ArgosiOS
//
//  Clave SSH del formulario de servidor, sin necesidad de un Mac: importar un archivo,
//  PEGAR el texto (como en Android) o CREAR un par Ed25519 en el propio iPhone y
//  enseñar la pública para copiarla o compartirla. Lo importado o pegado se revisa en el
//  momento con `SSHKeyInspector`: una RSA, una pública o un PEM antiguo se rechazan con
//  un mensaje claro, y si la clave lleva passphrase se marca sola.
//

import SwiftUI

/// Clave elegida en el formulario y aún sin guardar.
struct PendingKey: Equatable {
    let data: Data
    /// Línea pública, si la clave se creó aquí (para copiarla al servidor).
    let publicLine: String?
}

struct ServerKeySection: View {
    @Binding var pendingKey: PendingKey?
    @Binding var requiresPassphrase: Bool
    @Binding var secret: String
    let hasKey: Bool
    let needsSecret: Bool
    /// Clave ya guardada de este servidor (para enseñar su pública).
    let serverID: UUID
    let keyFromOtherDevice: Bool
    let keyPath: String

    @State private var isImporting = false
    @State private var isPasting = false
    @State private var issue: String?
    @State private var showingSavedPublicKey = false

    static let platformAlternative = String(localized: "usa «Crear clave en este iPhone»")

    var body: some View {
        Section {
            Menu {
                Button("Importar archivo…", systemImage: "doc") { isImporting = true }
                Button("Pegar clave…", systemImage: "doc.on.clipboard") { isPasting = true }
                Button("Crear clave en este iPhone", systemImage: "key.horizontal") { generate() }
            } label: {
                Label(hasKey ? "Clave lista · cambiar" : "Elegir clave privada…", systemImage: hasKey ? "key.fill" : "key")
            }
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let line = pendingKey?.publicLine {
                PublicKeyView(line: line)
            } else if hasKey, pendingKey == nil, !requiresPassphrase {
                DisclosureGroup("Clave pública", isExpanded: $showingSavedPublicKey) {
                    if let line = ImportedKeyStore.publicKeyLine(for: serverID, comment: "argos-\(UIDevice.current.model.lowercased())") {
                        PublicKeyView(line: line)
                    } else {
                        Text("No se pudo leer la clave guardada.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("La clave tiene passphrase", isOn: $requiresPassphrase)
                .disabled(pendingKey?.publicLine != nil)
            if requiresPassphrase {
                SecureField(needsSecret ? "Passphrase" : "Passphrase (vacía = sin cambios)", text: $secret)
            }
        } footer: {
            Text(footer)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data, .text, .item]) { result in
            importFile(result)
        }
        .sheet(isPresented: $isPasting) {
            PasteKeySheet { text in accept(Data(text.utf8)) }
        }
    }

    private var footer: String {
        if pendingKey?.publicLine != nil {
            return String(localized: "Añade esta clave pública a ~/.ssh/authorized_keys del servidor. Si ya entras con contraseña, es más fácil guardar el servidor con contraseña y usar «Usar una clave de este iPhone…» en su menú: Argos la instala y la prueba.")
        }
        if keyFromOtherDevice {
            return String(localized: "Este servidor llegó de tu Mac por iCloud con la clave «\(keyPath)», pero las claves no viajan. Importa o pega aquí una copia, o crea una clave nueva en este iPhone.")
        }
        return String(localized: "Argos admite claves Ed25519 en formato OpenSSH. Se guarda una copia privada en este dispositivo; la passphrase va al Llavero.")
    }

    // MARK: - Acciones

    private func generate() {
        let pair = DeviceKeyPair.generate()
        pendingKey = PendingKey(data: Data(pair.privateKeyPEM.utf8), publicLine: pair.authorizedKeyLine)
        requiresPassphrase = false
        issue = nil
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            accept(try Data(contentsOf: url))
        } catch {
            issue = error.userMessage
        }
    }

    /// Revisa la clave y, si sirve, la deja pendiente de guardar.
    private func accept(_ data: Data) {
        do {
            let (text, isEncrypted) = try ImportedKeyStore.validateSupported(data)
            pendingKey = PendingKey(data: Data(text.utf8), publicLine: nil)
            if isEncrypted { requiresPassphrase = true }
            issue = nil
        } catch let problem as SSHKeyProblem {
            issue = problem.userMessage(alternative: Self.platformAlternative)
        } catch {
            issue = error.userMessage
        }
    }
}

/// Clave pública con copiar y compartir.
struct PublicKeyView: View {
    let line: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
            HStack {
                Button(copied ? "Copiada" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = line
                    copied = true
                }
                .buttonStyle(.bordered)
                ShareLink(item: line) { Label("Compartir", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// Pegar una clave privada como texto (como `PasteKeyDialog` de Android).
struct PasteKeySheet: View {
    let onAccept: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var inspection: SSHKeyInspection? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : SSHKeyInspector.inspect(text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Pegar del portapapeles", systemImage: "doc.on.clipboard") {
                        text = UIPasteboard.general.string ?? ""
                    }
                } footer: {
                    Text("Pega la clave PRIVADA completa, desde «-----BEGIN OPENSSH PRIVATE KEY-----» hasta «-----END OPENSSH PRIVATE KEY-----». No sale de este dispositivo.")
                }
                if let inspection {
                    Section {
                        switch inspection {
                        case .supported(let encrypted, _):
                            Label(encrypted ? "Clave Ed25519 con passphrase" : "Clave Ed25519 lista", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .unsupported(let problem):
                            Label(problem.userMessage(alternative: ServerKeySection.platformAlternative), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Pegar clave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Usar") {
                        onAccept(text)
                        dismiss()
                    }
                    .disabled(inspection?.problem != nil || inspection == nil)
                }
            }
        }
    }
}
