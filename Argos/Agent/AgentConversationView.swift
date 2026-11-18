//
//  AgentConversationView.swift
//  Argos
//
//  Una conversación con Claude Code: transcript nativo (Markdown seguro, herramientas
//  con su icono y resultado plegable), tarjeta de permiso y caja de mensaje. Sirve igual
//  para una conversación de esta sesión y para un agente persistente del servidor
//  (`AgentConversationDriving`). Mientras Claude trabaja, «Detener» (o Esc) corta el turno
//  sin cerrar la conversación; una conversación terminada se puede reanudar.
//

import SwiftUI

struct AgentConversationView: View {
    let session: any AgentConversationDriving
    let title: String
    /// Reanudar la conversación terminada (`--resume`); `nil` si no se puede.
    var onResume: (() -> Void)? = nil

    /// El usuario está al final del transcript: solo entonces se sigue lo nuevo.
    @State private var isAtBottom = true
    @State private var draft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            transcript
            AgentConversationNotices(session: session)
            if let request = session.state.pendingPermission {
                AgentPermissionCard(
                    request: request,
                    onAllow: { Task { await session.allowPendingPermission() } },
                    onDeny: { Task { await session.denyPendingPermission() } }
                )
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            AgentComposer(session: session, draft: $draft, onResume: onResume)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.state.pendingPermission?.id)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.state.items.isEmpty {
                    AgentEmptyHint(
                        title: title,
                        workingDirectory: session.workingDirectory,
                        isEnabled: session.phase.acceptsMessages || session.phase.isBusy,
                        onSuggestion: { draft = $0 }
                    )
                } else {
                    transcriptItems
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - Self.bottomTolerance
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onChange(of: session.state.items.count) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var transcriptItems: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(session.state.items) { item in
                AgentItemRow(item: item).id(item.id)
            }
            if session.phase == .working {
                WorkingIndicator().id("working")
            }
        }
        .padding(24)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Si el usuario subió a leer algo, no se le arrastra al final.
        guard isAtBottom else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            if session.phase == .working {
                proxy.scrollTo("working", anchor: .bottom)
            } else if let last = session.state.items.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// Margen (pt) con el que se considera que el usuario está abajo del todo.
    static let bottomTolerance: CGFloat = 60
}

/// Avisos sobre la conversación: conexión al servidor (persistentes) y último error.
private struct AgentConversationNotices: View {
    let session: any AgentConversationDriving

    var body: some View {
        if let notice = session.connectionNotice {
            noticeLabel(notice.text, systemImage: "wifi.exclamationmark", color: .secondary)
        } else if session.phase == .resuming {
            noticeLabel("Reanudando el agente en el servidor…", systemImage: "play.circle", color: .secondary)
        }
        if let error = session.lastError {
            noticeLabel(error, systemImage: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func noticeLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentEmptyHint: View {
    let title: String
    let workingDirectory: String
    let isEnabled: Bool
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
            Text("¿En qué trabajamos en \(title)?")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Claude lee y edita los archivos de la carpeta del proyecto. Te pedirá permiso antes de "
                 + "ejecutar comandos o escribir.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(workingDirectory)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            VStack(spacing: 8) {
                suggestion("Explícame cómo está organizado este proyecto", icon: "square.stack.3d.up")
                suggestion("Revisa el código y encuentra posibles errores", icon: "ladybug")
            }
            .padding(.top, 8)
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
        .padding(.bottom, 28)
    }

    private func suggestion(_ text: String, icon: String) -> some View {
        Button {
            onSuggestion(text)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.tint).frame(width: 20)
                Text(text).font(.callout).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("Usar este mensaje como borrador")
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
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
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
