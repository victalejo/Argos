//
//  AgentConversationView.swift
//  Argos
//
//  Una conversación con Claude Code: transcript nativo (Markdown seguro, herramientas
//  con su icono y resultado plegable), tarjeta de permiso y caja de mensaje.
//

import SwiftUI

struct AgentConversationView: View {
    let session: ClaudeAgentSession
    let title: String

    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    private var isBusy: Bool {
        if session.state.pendingPermission != nil { return true }
        switch session.state.status {
        case .working, .connecting: return true
        case .idle, .finished, .failed: return false
        }
    }

    private var isClosed: Bool {
        switch session.state.status {
        case .finished, .failed: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let request = session.state.pendingPermission {
                AgentPermissionCard(
                    request: request,
                    onAllow: { session.allowPendingPermission() },
                    onDeny: { session.denyPendingPermission() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputBar
        }
        .animation(.snappy(duration: 0.2), value: session.state.pendingPermission?.id)
        .onAppear { isInputFocused = true }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.state.items.isEmpty {
                    emptyHint
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.state.items) { item in
                            AgentItemRow(item: item).id(item.id)
                        }
                        if session.state.status == .working && session.state.pendingPermission == nil {
                            WorkingIndicator().id("working")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: session.state.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if session.state.status == .working {
                        proxy.scrollTo("working", anchor: .bottom)
                    } else if let last = session.state.items.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
            Text("¿En qué trabajamos en \(title)?")
                .font(.title3.weight(.semibold))
            Text("Claude lee y edita los archivos de la carpeta del proyecto. Te pedirá permiso antes de "
                 + "ejecutar comandos o escribir.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(session.workingDirectory)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Entrada

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            if isClosed {
                Label("Esta conversación terminó. Abre otra con + o ⌘T.", systemImage: "stop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(isBusy ? "Claude está trabajando…" : "Escribe a Claude…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .focused($isInputFocused)
                        .onSubmit(send)
                        // Con un permiso pendiente, el ⏎ de lo que estabas escribiendo no
                        // debe llegar a la tarjeta de permiso.
                        .disabled(session.state.pendingPermission != nil)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Enviar (⏎). Mayús+⏎ para salto de línea.")
                }
                .padding(12)
            }
        }
        .background(.bar)
    }

    private var canSend: Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        session.sendUserText(draft)
        draft = ""
    }
}

// MARK: - Filas

private struct AgentItemRow: View {
    let item: AgentTranscriptItem

    var body: some View {
        switch item.kind {
        case .userText(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistantText(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)
                    .background(.orange.opacity(0.12), in: Circle())
                SafeMarkdownView(text: text, style: .chat)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .thinking:
            Label("Pensando…", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
                .padding(.leading, 32)
        case .toolUse(let name, let input):
            ToolUseRow(name: name, detail: AgentToolSummary.summary(name: name, input: input))
                .padding(.leading, 32)
        case .toolResult(let text, let isError):
            ToolResultRow(text: text, isError: isError)
                .padding(.leading, 32)
        case .result(let result):
            HStack(spacing: 5) {
                Image(systemName: result.isError ? "xmark.circle" : "checkmark.circle")
                Text(result.isError ? "Turno con error" : "Listo")
            }
            .font(.caption2)
            .foregroundStyle(result.isError ? .red : .secondary)
            .padding(.leading, 32)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

private struct ToolUseRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: AgentToolStyle.symbol(for: name))
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text(name).font(.caption.weight(.semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ToolResultRow: View {
    let text: String
    let isError: Bool
    @State private var isExpanded = false

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        let preview = lines.prefix(isExpanded ? lines.count : 3).joined(separator: "\n")
        VStack(alignment: .leading, spacing: 4) {
            Text(preview.isEmpty ? "(sin salida)" : preview)
                .font(.caption.monospaced())
                .foregroundStyle(isError ? .red : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if lines.count > 3 {
                Button(isExpanded ? "Mostrar menos" : "Mostrar \(lines.count - 3) líneas más") {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
        .padding(8)
        .background((isError ? Color.red : Color.secondary).opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            Rectangle().fill(isError ? Color.red.opacity(0.5) : Color.secondary.opacity(0.25)).frame(width: 2)
        }
    }
}

private struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
            Text("Claude está trabajando…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 2)
    }
}

// MARK: - Permiso

private struct AgentPermissionCard: View {
    let request: AgentPermissionRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    /// La tarjeta ignora acciones durante un instante tras aparecer, para que un clic o
    /// tecla que iba a otra cosa no apruebe sin querer.
    @State private var isArmed = false
    static let armingDelay: Duration = .milliseconds(600)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                Text("Claude quiere usar \(request.displayName ?? request.toolName)")
                    .font(.headline)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: AgentToolStyle.symbol(for: request.toolName))
                    .foregroundStyle(.tint)
                Text(AgentToolSummary.summary(name: request.toolName, input: request.input))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Permitir: clic o ⌘⏎ · Denegar: esc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Denegar", role: .cancel, action: onDeny)
                    .keyboardShortcut(.cancelAction)
                    .disabled(!isArmed)
                // Aprobar NUNCA es la acción por defecto (⏎): requiere clic o ⌘⏎.
                Button("Permitir", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isArmed)
            }
        }
        .task(id: request.id) {
            isArmed = false
            try? await Task.sleep(for: Self.armingDelay)
            isArmed = true
        }
        .padding(14)
        .background(.orange.opacity(0.10))
        .overlay(alignment: .top) { Divider() }
    }
}

/// Icono por herramienta de Claude Code.
enum AgentToolStyle {
    static func symbol(for tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep": return "magnifyingglass"
        case "Glob", "LS": return "folder"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}
