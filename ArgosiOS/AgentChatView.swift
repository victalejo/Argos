//
//  AgentChatView.swift
//  ArgosiOS
//
//  Conversación con un agente persistente. Al entrar se engancha al log del servidor
//  (reconstruye todo lo que pasó mientras no mirabas); al salir se desengancha y el
//  agente sigue trabajando.
//

import SwiftUI

struct AgentChatView: View {
    let session: PersistentAgentSession

    @State private var draft = ""
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
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
    }

    // MARK: - Transcripción

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.state.items.isEmpty {
                        ContentUnavailableView(
                            session.isAttached ? "Escribe tu primer mensaje" : "Conectando…",
                            systemImage: "sparkles",
                            description: Text("Claude Code trabajará en \(session.meta.workingDirectory).")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(session.state.items) { item in
                        TranscriptRow(item: item).id(item.id)
                    }
                    if session.state.status == .working {
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
            .onChange(of: session.state.items.count) { _, _ in
                withAnimation { proxy.scrollTo(session.state.items.last?.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(session.isAlive ? "Pide algo a Claude…" : "El agente está detenido", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .disabled(!session.isAlive)
            Button {
                let text = draft
                draft = ""
                Task { await session.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(!session.isAlive || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    Button("Reanudar conversación", systemImage: "play.circle") { Task { await session.resume() } }
                }
                Button("Recargar", systemImage: "arrow.clockwise") { session.attach() }
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
