//
//  AgentChatView.swift
//  ArgosiOS
//
//  Conversación con un agente persistente. Al entrar se engancha al log del servidor
//  (sigue desde lo último que viste); al salir se desengancha y el agente sigue
//  trabajando. Muestra el estado REAL de la conexión y reintenta solo si se corta. Un
//  agente hibernado se reanuda al escribirle. El borrador no se borra hasta que el
//  mensaje llega.
//

import SwiftUI

struct AgentChatView: View {
    let session: PersistentAgentSession

    @State private var draft = ""
    @State private var isSending = false
    @State private var confirmDelete = false
    @State private var confirmResume = false
    /// Mensaje que espera a que se confirme la reanudación para enviarse.
    @State private var pendingResumeText: String?
    /// El usuario está al final de la conversación: solo entonces se sigue lo nuevo.
    @State private var isAtBottom = true
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            connectionBanner
            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let request = session.state.pendingPermission {
                PermissionCard(request: request) { allow in
                    Task { allow ? await session.allowPendingPermission() : await session.denyPendingPermission() }
                }
            }
            composer
        }
        .navigationTitle(session.meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }

        .onAppear { session.attach() }
        .onDisappear { session.detach() }
        .confirmationDialog("¿Borrar esta conversación?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                Task {
                    await session.stop(delete: true)
                    dismiss()
                }
            }
        } message: {
            Text("Se detiene el agente y se borra su registro del servidor.")
        }
        .confirmationDialog("¿Reanudar en «\(resumeMode.title)»?", isPresented: $confirmResume, titleVisibility: .visible) {
            Button("Reanudar en «\(resumeMode.title)»", role: .destructive) { confirmedResume() }
            Button("Cancelar", role: .cancel) { pendingResumeText = nil }
        } message: {
            Text("El servidor indica que este agente usa este modo. \(resumeMode.detail) Si no lo elegiste tú, borra la conversación y crea otra.")
        }
    }

    private var resumeMode: ClaudeAgentCommand.PermissionMode {
        session.meta.resolvedPermissionMode
    }

    /// Se puede escribir: vivo, o hibernado (escribir lo reanuda).
    private var canCompose: Bool { session.isAlive || session.meta.isHibernated }

    private var composerPlaceholder: String {
        if session.isAlive { return "Pide algo a Claude…" }
        return session.meta.isHibernated ? "En reposo: escribe para reanudarlo" : "El agente está detenido"
    }

    private var emptyTitle: String {
        switch session.link {
        case .live: return "Escribe tu primer mensaje"
        case .reconnecting: return "Reconectando…"
        case .connecting, .detached: return "Conectando…"
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if case .reconnecting(let attempt) = session.link {
            Label(attempt > 1 ? "Sin conexión con el servidor. Reintentando (\(attempt))…" : "Reconectando con el servidor…",
                  systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if session.isResuming {
            Label("Reanudando el agente…", systemImage: "play.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        // Se oculta el teclado para ver la respuesta (tocar el campo lo reabre).
        composerFocused = false
        isSending = true
        Task {
            defer { isSending = false }
            handle(await session.send(text), text: text)
        }
    }

    private func confirmedResume() {
        guard let text = pendingResumeText else {
            Task { await session.resume() }
            return
        }
        pendingResumeText = nil
        isSending = true
        Task {
            defer { isSending = false }
            handle(await session.send(text, confirmedResume: true), text: text)
        }
    }

    /// El borrador solo se vacía si el mensaje LLEGÓ (y si no se ha cambiado mientras).
    private func handle(_ outcome: AgentSendOutcome, text: String) {
        switch outcome {
        case .sent:
            if draft == text { draft = "" }
        case .needsResumeConfirmation:
            pendingResumeText = text
            confirmResume = true
        case .failed:
            break
        }
    }

    // MARK: - Transcripción

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.state.items.isEmpty {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: "sparkles",
                            description: Text("Claude Code trabajará en \(session.meta.workingDirectory).")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(session.state.items) { item in
                        TranscriptRow(item: item).id(item.id)
                    }
                    if session.state.status == .working, session.link.isLive {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Trabajando…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onChange(of: session.state.items.count) { _, _ in
                // Si el usuario subió a leer algo, no se le arrastra al final.
                guard isAtBottom else { return }
                withAnimation { proxy.scrollTo(session.state.items.last?.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(composerPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .disabled(!canCompose)
            Button(action: submit) {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
            }
            .disabled(!canCompose || isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Enviar")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Opciones", systemImage: "ellipsis.circle") {
                if session.isAlive {
                    Button("Detener agente", systemImage: "stop.circle") { Task { await session.stop() } }
                } else {
                    Button("Reanudar conversación", systemImage: "play.circle") {
                        pendingResumeText = nil
                        if session.meta.resumeRequiresConfirmation {
                            confirmResume = true
                        } else {
                            Task { await session.resume() }
                        }
                    }
                }
                Button("Recargar", systemImage: "arrow.clockwise") { session.reload() }
                Divider()
                Button("Borrar conversación", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
    }
}

// MARK: - Piezas

private struct TranscriptRow: View {
    let item: AgentTranscriptItem

    var body: some View {
        switch item.kind {
        case .userText(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
            }
        case .assistantText(let text):
            MarkdownText(text: text)
                .textSelection(.enabled)
        case .thinking(let text):
            DisclosureGroup("Pensando") {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .toolUse(let name, let input):
            Label(AgentToolSummary.summary(name: name, input: input), systemImage: "wrench.and.screwdriver")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .toolResult(let text, let isError):
            if isError {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }
        case .result(let result):
            HStack(spacing: 6) {
                Image(systemName: result.isError ? "xmark.circle" : "checkmark.circle")
                Text(result.isError ? "Terminó con error" : "Listo")
                if let cost = result.totalCostUSD {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                }
            }
            .font(.caption)
            .foregroundStyle(result.isError ? .red : .green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.octagon")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

private struct PermissionCard: View {
    let request: AgentPermissionRequest
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Claude quiere usar \(request.displayName ?? request.toolName)", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            Text(AgentToolSummary.summary(name: request.toolName, input: request.input))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(5)
            HStack {
                Button("Denegar", role: .destructive) { decide(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Permitir") { decide(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.orange.opacity(0.12))
    }
}
