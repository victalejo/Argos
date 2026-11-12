//
//  ClaudeLoginSheet.swift
//  ArgosiOS
//
//  «Conectar Claude» en el iPhone/iPad: inicia sesión de Claude en el SERVIDOR con
//  pasos guiados (`ClaudeLoginModel`), como la hoja del Mac. La página de autorización
//  se abre DENTRO de la app: salir a Safari mandaría Argos a segundo plano, iOS
//  cortaría el SSH y el inicio de sesión se cancelaría.
//

import SwiftUI

struct ClaudeLoginSheet: View {
    let serverName: String
    /// Ofrece seguir sin iniciar sesión (cuando la hoja interrumpe la creación de un
    /// agente): `claude auth status` puede no reconocer una sesión que sí existe.
    var allowsSkip = false
    /// `true` si la sesión quedó iniciada (o el usuario eligió seguir sin comprobarla).
    let onFinish: (Bool) -> Void

    @State private var model: ClaudeLoginModel
    @State private var code = ""
    @State private var browsing: AuthorizationPage?
    @State private var didOpenPage = false
    @State private var showDetails = false
    @State private var didStart = false

    /// Cuánto se ve la confirmación antes de cerrarse sola.
    private static let successDisplay: Duration = .milliseconds(1600)

    init(service: any SSHServicing, serverName: String, allowsSkip: Bool = false, onFinish: @escaping (Bool) -> Void) {
        self.serverName = serverName
        self.allowsSkip = allowsSkip
        self.onFinish = onFinish
        _model = State(initialValue: ClaudeLoginModel(service: service))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Inicia sesión con tu cuenta de Claude (suscripción) en \(serverName). El agente nunca usa la API de pago.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                authorizeSection
                codeSection
                resultSection
                detailsSection
            }
            .navigationTitle("Conectar Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { onFinish(false) }
                }
                if isSuccess {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continuar") { onFinish(true) }
                    }
                }
            }
            .fullScreenCover(item: $browsing) { page in
                SafariView(url: page.url).ignoresSafeArea()
            }
        }
        .interactiveDismissDisabled(model.phase == .verifying)
        .onAppear {
            // Una sola vez: relanzar el comando al volver de la página de autorización
            // invalidaría el enlace (y el código) que el usuario acaba de usar.
            guard !didStart else { return }
            didStart = true
            model.start()
        }
        .onDisappear { if browsing == nil { model.stop() } }
        // Se cancela sola si la hoja se cierra antes (p. ej. con «Continuar»).
        .task(id: isSuccess) {
            guard isSuccess else { return }
            if case .success(let message) = model.phase {
                AccessibilityNotification.Announcement(message).post()
            }
            do { try await Task.sleep(for: Self.successDisplay) } catch { return }
            onFinish(true)
        }
    }

    private var isSuccess: Bool {
        if case .success = model.phase { return true }
        return false
    }

    private var isPastAuthorize: Bool {
        switch model.phase {
        case .verifying, .success: return true
        case .starting, .authorize, .failed: return false
        }
    }

    // MARK: - Pasos

    private var authorizeSection: some View {
        Section {
            Button {
                if let url = model.authorizationURL {
                    browsing = AuthorizationPage(url: url)
                    didOpenPage = true
                }
            } label: {
                Label(didOpenPage ? "Abrir de nuevo" : "Abrir página de autorización", systemImage: "safari")
            }
            .disabled(model.authorizationURL == nil || isPastAuthorize)
            Button {
                UIPasteboard.general.string = model.authorizationURL?.absoluteString
            } label: {
                Label("Copiar enlace", systemImage: "doc.on.doc")
            }
            .disabled(model.authorizationURL == nil || isPastAuthorize)
            if model.phase == .starting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparando…").foregroundStyle(.secondary)
                }
            }
        } header: {
            stepHeader(1, "Autoriza con tu cuenta", done: didOpenPage || isPastAuthorize)
        } footer: {
            Text("No salgas de Argos hasta terminar: el inicio de sesión se cancelaría. Con «Copiar enlace» puedes autorizar desde otro dispositivo.")
        }
    }

    private var codeSection: some View {
        Section {
            HStack {
                TextField("Código de autorización", text: $code)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(submit)
                Button("Pegar") {
                    if let pasted = UIPasteboard.general.string { code = pasted }
                }
                .buttonStyle(.borderless)
            }
            .disabled(!model.canSubmitCode)
            Button("Confirmar", action: submit)
                .disabled(!model.canSubmitCode || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            stepHeader(2, "Pega el código que te da la página", done: isPastAuthorize)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch model.phase {
        case .verifying:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Comprobando la sesión…").foregroundStyle(.secondary)
                }
            }
        case .success(let message):
            Section {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Empezar de nuevo", systemImage: "arrow.clockwise") {
                    code = ""
                    didOpenPage = false
                    model.start()
                }
                if allowsSkip {
                    Button("Continuar sin iniciar sesión", systemImage: "arrow.right.circle") { onFinish(true) }
                }
            }
        case .starting, .authorize:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        if !model.transcript.isEmpty {
            Section {
                DisclosureGroup("Detalles técnicos", isExpanded: $showDetails) {
                    Text(verbatim: model.transcript)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func stepHeader(_ number: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(done ? "Paso \(number), hecho: \(title)" : "Paso \(number): \(title)")
    }

    private func submit() {
        model.submit(code: code)
    }
}

private struct AuthorizationPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
