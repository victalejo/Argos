//
//  ClaudeSetupSheet.swift
//  Argos
//
//  Conectar (login) o instalar Claude Code en el SERVIDOR con una UI guiada en vez
//  de un terminal crudo. El comando corre igualmente en un PTY remoto (es el flujo
//  oficial), pero Argos lee su salida (`ClaudeLoginOutput`) y la convierte en pasos:
//    1. Abrir la página de autorización en el navegador del Mac.
//    2. Pegar el código en un campo normal (Argos lo teclea en el PTY).
//    3. Verificar con `claude auth status` y cerrarse solo.
//  El terminal sigue disponible en "Ver detalles" por si algo no encaja.
//

import AppKit
import SwiftUI

struct ClaudeSetupSheet: View {
    enum Purpose: Equatable {
        /// `claude auth login --claudeai` (comando ya construido con la ruta del binario).
        case login(command: String)
        /// Instalador oficial de Claude Code.
        case install

        static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    }

    let service: any SSHServicing
    let serverName: String
    let purpose: Purpose
    /// `true` si terminó con éxito (sesión iniciada / Claude instalado).
    let onFinish: (Bool) -> Void

    private enum Phase: Equatable {
        case starting
        case authorize          // enlace disponible, esperando que el usuario autorice
        case verifying          // código enviado / instalación terminada: comprobando
        case success(String)
        case failed(String)
    }

    @State private var controller: LiveTerminalController?
    @State private var settings = TerminalSettings.shared
    @State private var output = ""
    @State private var parsed = ClaudeLoginOutput(authorizationURL: nil, isAwaitingCode: false)
    @State private var didOpenBrowser = false
    @State private var code = ""
    @State private var phase: Phase = .starting
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch purpose {
            case .login: loginSteps
            case .install: installSteps
            }
            if showDetails || purpose == .install {
                terminal
                    .frame(height: purpose == .install ? 260 : 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
            footer
        }
        .padding(22)
        .frame(width: 600)
        .task { startIfNeeded() }
        .onDisappear { controller?.stop() }
        .onChange(of: controller?.status) { _, status in
            if status == .ended || status.map({ if case .failed = $0 { return true } else { return false } }) == true {
                Task { await processEnded() }
            }
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: purpose == .install ? "arrow.down.circle.fill" : "person.badge.key.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(purpose == .install ? "Instalar Claude Code en \(serverName)" : "Conectar Claude en \(serverName)")
                    .font(.title2.weight(.semibold))
                Text(purpose == .install
                     ? "Se ejecuta el instalador oficial de Anthropic en el servidor. Tarda menos de un minuto."
                     : "Inicia sesión con tu cuenta de Claude (suscripción). El agente nunca usa la API de pago.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Login

    @ViewBuilder
    private var loginSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, title: "Autoriza en el navegador", done: didOpenBrowser || isPastAuthorize) {
                HStack(spacing: 8) {
                    Button {
                        openBrowser()
                    } label: {
                        Label(didOpenBrowser ? "Abrir de nuevo" : "Abrir página de autorización", systemImage: "safari")
                    }
                    .disabled(parsed.authorizationURL == nil)
                    Button {
                        if let url = parsed.authorizationURL {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    } label: {
                        Label("Copiar enlace", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(parsed.authorizationURL == nil)
                    if parsed.authorizationURL == nil, phase == .starting {
                        ProgressView().controlSize(.small)
                        Text("Preparando…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            step(2, title: "Pega el código que te da la página", done: isPastAuthorize) {
                HStack(spacing: 8) {
                    TextField("Código de autorización", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(submitCode)
                        .disabled(!parsed.isAwaitingCode || isPastAuthorize)
                    Button("Confirmar", action: submitCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(!parsed.isAwaitingCode || code.trimmingCharacters(in: .whitespaces).isEmpty || isPastAuthorize)
                }
            }
            step(3, title: "Listo", done: { if case .success = phase { return true } else { return false } }()) {
                resultLine
            }
        }
    }

    private var isPastAuthorize: Bool {
        switch phase {
        case .verifying, .success: return true
        default: return false
        }
    }

    // MARK: - Instalación

    private var installSteps: some View {
        resultLine
    }

    @ViewBuilder
    private var resultLine: some View {
        switch phase {
        case .verifying:
            Label {
                Text(purpose == .install ? "Comprobando la instalación…" : "Comprobando la sesión…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .starting, .authorize:
            if purpose == .install {
                Label("Instalando…", systemImage: "hourglass").foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }

    private func step<Content: View>(_ number: Int, title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold()).foregroundStyle(.tint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    // MARK: - Terminal y pie

    @ViewBuilder
    private var terminal: some View {
        if let controller {
            TerminalViewRepresentable(controller: controller, fontSize: settings.fontSize, theme: settings.theme)
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack {
            if purpose != .install {
                Button(showDetails ? "Ocultar detalles" : "Ver detalles técnicos") { showDetails.toggle() }
                    .buttonStyle(.link)
            }
            Spacer()
            if case .success = phase {
                Button("Continuar") { onFinish(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancelar", role: .cancel) { onFinish(false) }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Flujo

    private func startIfNeeded() {
        guard controller == nil else { return }
        let command: String
        switch purpose {
        case .login(let loginCommand): command = loginCommand
        case .install: command = Purpose.installCommand
        }
        let controller = LiveTerminalController(service: service, command: command)
        controller.onOutput = { bytes in
            output += String(decoding: bytes, as: UTF8.self)
            // Acota lo que se analiza: el enlace y el prompt llegan al principio.
            if output.count > 20_000 { output = String(output.suffix(20_000)) }
            parsed = ClaudeLoginOutput.parse(output)
            if parsed.authorizationURL != nil, phase == .starting { phase = .authorize }
            if parsed.authorizationURL != nil, !didOpenBrowser, case .login = purpose { openBrowser() }
        }
        self.controller = controller
    }

    private func openBrowser() {
        guard let url = parsed.authorizationURL else { return }
        NSWorkspace.shared.open(url)
        didOpenBrowser = true
    }

    private func submitCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, parsed.isAwaitingCode else { return }
        controller?.sendText(trimmed + "\r")
        phase = .verifying
        Task { await verifyLogin() }
    }

    /// Tras pegar el código, sondea `claude auth status` hasta ~60 s.
    private func verifyLogin() async {
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(2))
            if let status = try? await service.claudeAuthStatus(), status.loggedIn {
                succeed(loginMessage(status))
                return
            }
        }
        phase = .failed("No se pudo confirmar la sesión. Revisa el código o abre los detalles técnicos.")
        showDetails = true
    }

    /// El comando terminó: en la instalación, comprobamos que `claude` existe; en el
    /// login, si no se había confirmado aún, verificamos una última vez.
    private func processEnded() async {
        switch purpose {
        case .install:
            phase = .verifying
            if let path = try? await service.locateClaude() {
                succeed("Claude Code instalado (\(path)).")
            } else {
                phase = .failed("La instalación no terminó bien. Revisa la salida de arriba.")
            }
        case .login:
            if case .success = phase { return }
            if let status = try? await service.claudeAuthStatus(), status.loggedIn {
                succeed(loginMessage(status))
            } else if phase != .verifying {
                phase = .failed("El inicio de sesión se cerró sin completarse.")
                showDetails = true
            }
        }
    }

    private func succeed(_ message: String) {
        phase = .success(message)
        // Se cierra solo tras un momento para que se vea la confirmación.
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            onFinish(true)
        }
    }

    private func loginMessage(_ status: ClaudeAuthStatus) -> String {
        var parts = ["Conectado"]
        if let plan = status.subscriptionType, !plan.isEmpty { parts.append("plan \(plan.capitalized)") }
        if let email = status.email { parts.append(email) }
        return parts.joined(separator: " · ")
    }
}
