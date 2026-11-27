//
//  AgentComposer.swift
//  Argos
//
//  Caja de mensaje de una conversación con Claude (de esta sesión o persistente). El
//  borrador solo se vacía si el mensaje LLEGÓ. Un agente persistente en reposo se reanuda
//  al escribirle; si su modo actúa sin preguntar («Todos los permisos», «Aceptar
//  ediciones»), se pide confirmación antes (como en el iPhone).
//

import SwiftUI

struct AgentComposer: View {
    let session: any AgentConversationDriving
    @Binding var draft: String
    let onResume: (() -> Void)?

    @State private var isSending = false
    /// Mensaje que espera a que se confirme la reanudación para enviarse.
    @State private var pendingResumeText: String?
    @FocusState private var isFocused: Bool
    @Environment(\.savedPromptContext) private var promptContext

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if case .stopped(let reason) = session.phase {
                AgentStoppedBar(reason: reason, onResume: onResume)
            } else {
                editor
            }
        }
        .background(.bar)
        .onAppear { isFocused = true }
        .confirmationDialog(
            "¿Reanudar en «\(session.resumeConfirmationMode?.title ?? "")»?",
            isPresented: Binding(get: { pendingResumeText != nil }, set: { if !$0 { pendingResumeText = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reanudar en «\(session.resumeConfirmationMode?.title ?? "")»", role: .destructive) { confirmResume() }
            Button("Cancelar", role: .cancel) { pendingResumeText = nil }
        } message: {
            Text(String(localized: "El servidor indica que este agente usa este modo. \(session.resumeConfirmationMode?.detail ?? "") Si no lo elegiste tú, detenlo y abre otra conversación."))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(send)
                // Con un permiso pendiente, el ⏎ de lo que estabas escribiendo no debe
                // llegar a la tarjeta de permiso.
                .disabled(session.state.pendingPermission != nil)
                .font(.body)
                .accessibilityLabel("Mensaje para Claude")
            HStack(spacing: 8) {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let promptContext, !promptContext.prompts.isEmpty { promptMenu(promptContext) }
                if session.phase == .working { interruptButton }
                sendButton
            }
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isFocused ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Biblioteca de encargos: pone el prompt (con sus variables rellenas) en el borrador.
    private func promptMenu(_ context: SavedPromptContext) -> some View {
        SavedPromptMenu(prompts: context.prompts) { (prompt: SavedPrompt) in
            Task {
                draft = await context.expand(prompt.text)
                isFocused = true
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    /// Esc/«Detener» solo mientras trabaja SIN permiso pendiente (ahí Esc es «Denegar»).
    private var interruptButton: some View {
        Button {
            Task { await session.interruptTurn() }
        } label: {
            Label(session.isInterrupting ? "Deteniendo…" : "Detener", systemImage: "stop.fill")
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .keyboardShortcut(.cancelAction)
        .disabled(session.isInterrupting)
        .help("Detener lo que está haciendo Claude (esc). La conversación sigue abierta.")
    }

    private var sendButton: some View {
        Button(action: send) {
            if isSending {
                ProgressView().controlSize(.small)
            } else {
                Label("Enviar", systemImage: "arrow.up").font(.callout.weight(.semibold))
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!canSend)
        .help("Enviar (⏎). Mayús+⏎ para salto de línea.")
    }

    private var placeholder: String {
        switch session.phase {
        case .asleep: return String(localized: "En reposo: escribe para reanudarlo")
        case .resuming: return String(localized: "Reanudando…")
        case .working, .awaitingPermission: return String(localized: "Claude está trabajando…")
        case .ready, .stopped: return String(localized: "Escribe a Claude…")
        }
    }

    private var hint: String {
        session.phase.isBusy ? String(localized: "Puedes preparar tu siguiente mensaje") : String(localized: "⏎ enviar · ⇧⏎ nueva línea")
    }

    private var canSend: Bool {
        !isSending && session.phase.acceptsMessages && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        deliver(draft, confirmedResume: false)
    }

    private func confirmResume() {
        guard let text = pendingResumeText else { return }
        pendingResumeText = nil
        deliver(text, confirmedResume: true)
    }

    private func deliver(_ text: String, confirmedResume: Bool) {
        isSending = true
        Task {
            defer { isSending = false }
            switch await session.submit(text, confirmedResume: confirmedResume) {
            case .sent:
                if draft == text { draft = "" }
            case .needsResumeConfirmation:
                pendingResumeText = text
            case .failed:
                break
            }
        }
    }
}

/// Barra de una conversación cuyo `claude` no está en marcha.
private struct AgentStoppedBar: View {
    let reason: AgentConversationPhase.StopReason
    let onResume: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: reason == .connectionLost ? "wifi.exclamationmark" : "stop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let onResume {
                Button("Reanudar conversación", systemImage: "play.circle", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .help("Vuelve a abrir esta conversación con Claude (--resume)")
            }
        }
        .padding(12)
    }

    private var text: String {
        let suffix = onResume == nil ? String(localized: " Abre otra con + o ⌘T.") : ""
        switch reason {
        case .connectionLost: return String(localized: "Se perdió la conexión con el servidor.") + suffix
        case .ended: return String(localized: "Esta conversación terminó.") + suffix
        case .agentStopped: return String(localized: "El agente está detenido en el servidor.") + suffix
        }
    }
}
