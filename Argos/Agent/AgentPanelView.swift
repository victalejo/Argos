//
//  AgentPanelView.swift
//  Argos
//
//  Panel de Claude Code (opción "Agente" de la 3ª columna; el terminal tmux sigue
//  siendo el modo por defecto). Renderiza la conversación stream-json como UI nativa:
//  mensajes, tool calls y permisos con botones Permitir/Denegar.
//
//  Tres fases:
//   1. Sin token de suscripción guardado → instrucciones + pegar token.
//   2. Token presente, agente no iniciado → elegir directorio remoto + iniciar.
//   3. Agente vivo → conversación.
//

import SwiftUI

struct AgentPanelView: View {
    let handle: SessionHandle
    let service: any SSHServicing
    let store: AgentSessionStore

    @State private var tokenPresent = false
    @State private var tokenInput = ""
    @State private var workingDirectory = "~"
    @State private var isStarting = false
    @State private var startError: String?

    // Estado de autenticación del servidor + flujo de login.
    @State private var authStatus: ClaudeAuthStatus?
    @State private var checkingAuth = false
    @State private var authChecked = false
    @State private var preparingLogin = false
    @State private var loginCommand: String?
    @State private var showLogin = false

    var body: some View {
        VStack(spacing: 0) {
            alphaBanner
            Divider()
            content
        }
        .onAppear {
            tokenPresent = KeychainStore.hasClaudeOAuthToken()
            checkAuth()
        }
        .sheet(isPresented: $showLogin) {
            if let loginCommand {
                RemoteLoginSheet(service: service, command: loginCommand) {
                    showLogin = false
                    checkAuth()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = store.existing(for: handle) {
            AgentConversationView(session: session) { store.close(handle) }
        } else {
            startForm
        }
    }

    /// Aviso permanente de que el panel de agente es experimental.
    private var alphaBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "flask.fill")
            Text("Agente (alfa) — función experimental; puede fallar o cambiar.")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.12))
    }

    // MARK: - Iniciar el agente

    private var startForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Iniciar agente de Claude Code")
                .font(.headline)
            Text("Se ejecutará `claude` en ESTE servidor (no en tu Mac), en el directorio "
                 + "que indiques. Siempre usa tu suscripción, nunca la API.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            TextField("Directorio de trabajo remoto (p. ej. ~/miproyecto)", text: $workingDirectory)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { startAgent() }
                .frame(maxWidth: 460)

            authSection

            if let startError {
                Text(startError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button {
                startAgent()
            } label: {
                if isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Iniciar agente", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isStarting || workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Autenticación del servidor

    private var authSection: some View {
        VStack(spacing: 10) {
            authStatusRow

            if authChecked, authStatus?.loggedIn != true {
                Button { startLogin() } label: {
                    if preparingLogin {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Iniciar sesión en el servidor", systemImage: "person.badge.key")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(preparingLogin)
            }

            tokenDisclosure
        }
        .frame(maxWidth: 460)
    }

    @ViewBuilder
    private var authStatusRow: some View {
        if checkingAuth {
            Label("Comprobando sesión del servidor…", systemImage: "circle.dotted")
                .font(.caption).foregroundStyle(.secondary)
        } else if let authStatus, authStatus.loggedIn {
            Label("Servidor autenticado" + (authStatus.subscriptionType.map { " · \($0)" } ?? ""),
                  systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else if authChecked, authStatus == nil {
            Label("`claude` no está instalado en el servidor", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.orange)
        } else if authChecked {
            Label("Este servidor no tiene sesión de Claude", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var tokenDisclosure: some View {
        DisclosureGroup("Usar un token en su lugar (avanzado)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Alternativa al login del servidor: pega un token de `claude setup-token` "
                     + "(generado en tu Mac). También usa tu plan, nunca la API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if tokenPresent {
                    HStack {
                        Label("Token guardado", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Quitar") {
                            KeychainStore.deleteClaudeOAuthToken()
                            tokenPresent = false
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                } else {
                    HStack {
                        SecureField("Token (claude setup-token)", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Guardar") { saveToken() }
                            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func checkAuth() {
        guard !checkingAuth else { return }
        checkingAuth = true
        Task {
            defer { checkingAuth = false }
            authStatus = try? await service.claudeAuthStatus()
            authChecked = true
        }
    }

    private func startLogin() {
        guard !preparingLogin else { return }
        preparingLogin = true
        startError = nil
        Task {
            defer { preparingLogin = false }
            do {
                guard let claudePath = try await service.locateClaude() else {
                    startError = "No se encontró 'claude' en el servidor para iniciar sesión."
                    return
                }
                loginCommand = "\(ShellQuoting.singleQuoted(claudePath)) auth login --claudeai"
                showLogin = true
            } catch {
                startError = error.userMessage
            }
        }
    }

    private func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try KeychainStore.setClaudeOAuthToken(token)
            tokenInput = ""
            tokenPresent = true
        } catch {
            startError = error.userMessage
        }
    }

    private func startAgent() {
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return }

        // Token OPCIONAL: si no hay, se usa la credencial de `claude login` del servidor.
        let token = KeychainStore.claudeOAuthToken()

        isStarting = true
        startError = nil
        Task {
            defer { isStarting = false }
            do {
                guard let claudePath = try await service.locateClaude() else {
                    startError = "No se encontró 'claude' en el servidor. Instálalo allí "
                        + "(p. ej. con el instalador oficial) e inténtalo de nuevo."
                    return
                }
                guard try await service.remoteDirectoryExists(directory) else {
                    startError = "El directorio '\(directory)' no existe en el servidor. "
                        + "Usa una ruta válida (por ejemplo ~ o la ruta de tu repo)."
                    return
                }
                let command = ClaudeAgentCommand.build(
                    claudePath: claudePath,
                    workingDirectory: directory,
                    oauthToken: token,
                    sessionID: UUID().uuidString
                )
                store.start(
                    for: handle,
                    service: service,
                    command: command,
                    workingDirectory: directory
                )
            } catch {
                startError = error.userMessage
            }
        }
    }
}

// MARK: - Conversación

private struct AgentConversationView: View {
    let session: ClaudeAgentSession
    let onClose: () -> Void

    @State private var draft = ""

    private var inputDisabled: Bool {
        if session.state.pendingPermission != nil { return true }
        switch session.state.status {
        case .working, .connecting, .finished, .failed: return true
        case .idle: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let request = session.state.pendingPermission {
                Divider()
                AgentPermissionCard(
                    request: request,
                    onAllow: { session.allowPendingPermission() },
                    onDeny: { session.denyPendingPermission() }
                )
            }
            Divider()
            inputBar
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusBadge
            Text(session.workingDirectory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(role: .destructive) {
                onClose()
            } label: {
                Label("Detener", systemImage: "stop.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusBadge: some View {
        badgeLabel.font(.caption)
    }

    @ViewBuilder
    private var badgeLabel: some View {
        switch session.state.status {
        case .connecting:
            Label("Conectando…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .idle:
            Label("Listo", systemImage: "circle.fill").foregroundStyle(.green)
        case .working:
            Label("Trabajando…", systemImage: "circle.fill").foregroundStyle(.orange)
        case .finished:
            Label("Sesión terminada", systemImage: "circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.state.items) { item in
                        AgentItemRow(item: item).id(item.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: session.state.items.count) { _, _ in
                if let last = session.state.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Escribe un mensaje para el agente…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit(send)
                .disabled(inputDisabled)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(inputDisabled || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private func send() {
        let text = draft
        draft = ""
        session.sendUserText(text)
    }
}

// MARK: - Filas del transcript

private struct AgentItemRow: View {
    let item: AgentTranscriptItem

    var body: some View {
        switch item.kind {
        case .userText(let text):
            bubble(text, alignment: .trailing, role: "Tú", color: .blue.opacity(0.15))
        case .assistantText(let text):
            bubble(text, alignment: .leading, role: "Claude", color: .gray.opacity(0.12))
        case .thinking(let text):
            Label(text, systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        case .toolUse(let name, let input):
            toolRow(name: name, detail: AgentToolSummary.summary(name: name, input: input))
        case .toolResult(let text, let isError):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .result(let result):
            resultRow(result)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func bubble(_ text: String, alignment: HorizontalAlignment, role: String, color: Color) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(role).font(.caption2).foregroundStyle(.secondary)
            Text(.init(text))                       // Markdown básico
                .textSelection(.enabled)
                .padding(8)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    private func toolRow(name: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.tint)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption.bold())
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultRow(_ result: AgentResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.isError ? "xmark.circle" : "checkmark.circle")
                .foregroundStyle(result.isError ? .red : .green)
            Text(result.isError ? "Turno con error" : "Turno completado")
            if let cost = result.totalCostUSD {
                Text(String(format: "· $%.4f", cost)).foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Tarjeta de permiso

private struct AgentPermissionCard: View {
    let request: AgentPermissionRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permiso solicitado", systemImage: "lock.shield")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            HStack(spacing: 6) {
                Text(request.displayName ?? request.toolName).font(.callout.bold())
                Text(AgentToolSummary.summary(name: request.toolName, input: request.input))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Spacer()
                Button("Denegar", role: .cancel) { onDeny() }
                Button("Permitir") { onAllow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08))
    }
}
