//
//  ClaudeTasksView.swift
//  ArgosUI
//
//  Cola de encargos de un proyecto (Mac e iPhone/iPad): añadir un encargo, ver los que
//  esperan, el que está en curso y los terminados, y cancelar o reintentar.
//

import SwiftUI

struct ClaudeTasksView: View {
    @Bindable var model: ClaudeTasksModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.needsHooks { hooksNotice }
            ClaudeTaskComposer(model: model)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            queue
            ClaudeBudgetSection(model: model.budget)
        }
        .task { await model.watch() }
        .task { await model.budget.watch() }
    }

    private var hooksNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("La cola necesita el indicador de Claude", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Sus hooks avisan cuando Claude termina, y así empieza el siguiente encargo aunque la app esté cerrada.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Activar el indicador") { Task { await model.installHooks() } }
                .disabled(model.isWorking)
        }
    }

    @ViewBuilder
    private var queue: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity)
        } else if model.openTasks.isEmpty && model.finishedTasks.isEmpty {
            Text("No hay encargos. Escribe uno arriba: empezará en cuanto Claude quede libre, y los siguientes, al terminar el anterior.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            section("Cola", tasks: model.openTasks)
            section("Terminados", tasks: model.finishedTasks)
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, tasks: [ClaudeTask]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(tasks) { task in
                    row(task)
                }
            }
        }
    }
}

extension ClaudeTasksView {
    @ViewBuilder
    fileprivate func row(_ task: ClaudeTask) -> some View {
        ClaudeTaskRow(
            item: task,
            budgetBlock: model.budget.activeBlock(),
            onCancel: { Task { await model.cancel(task) } },
            onRetry: { Task { await model.retry(task) } }
        )
        if task.isBlockedByReview {
            ClaudeTaskReviewView(
                task: task,
                isWorking: model.isWorking,
                onPushAnyway: { Task { await model.pushAnyway(task) } },
                onFix: { Task { await model.requestFix(task) } }
            )
            .padding(.leading, 28)
        }
    }
}

/// Formulario del encargo nuevo.
private struct ClaudeTaskComposer: View {
    @Bindable var model: ClaudeTasksModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.draft)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .accessibilityLabel(Text("Encargo para Claude"))
            options
            HStack {
                if !model.savedPrompts.isEmpty {
                    SavedPromptMenu(prompts: model.savedPrompts) { (prompt: SavedPrompt) in
                        Task { await model.usePrompt(prompt) }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Añadir a la cola") { Task { await model.add() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAdd)
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        Toggle("En un agente aparte, en su propia rama (worktree)", isOn: $model.inAgent)
        if !model.inAgent && model.claudeWindows.count > 1 {
            Picker("Ventana", selection: $model.window) {
                ForEach(model.claudeWindows.keys.sorted(), id: \.self) { (index: Int) in
                    Text("Ventana \(index)").tag(index)
                }
            }
        }
        if !model.inAgent {
            Toggle("Empezar con la conversación limpia (/clear)", isOn: $model.cleanContext)
        }
        Toggle("Hacer commit al terminar", isOn: $model.commit)
    }
}

private struct ClaudeTaskRow: View {
    let item: ClaudeTask
    /// Bloqueo del presupuesto del proyecto (detalla el motivo `budget`).
    let budgetBlock: ClaudeBudgetBlock?
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            actions
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [item.state?.label ?? String(localized: "Desconocido")]
        if let reason = item.reason, item.state == .pending || item.state == .paused || item.state == .failed || item.state == .done {
            if reason == .budget, let budgetBlock {
                parts.append(budgetBlock.message())
            } else {
                parts.append(reason.text)
            }
        }
        if item.reason == nil, item.reviewedVerdict == ClaudeTaskReview.Verdict.approve.rawValue {
            parts.append(String(localized: "Aprobado por el revisor automático."))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .running: ProgressView().controlSize(.small)
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled, .none: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .pending:
            Button("Cancelar", action: onCancel).buttonStyle(.borderless)
        case .paused where item.isBlockedByReview:
            Button("Cancelar", action: onCancel).buttonStyle(.borderless)
        case .paused:
            HStack(spacing: 8) {
                Button("Reanudar", action: onRetry).buttonStyle(.borderless)
                Button("Cancelar", action: onCancel).buttonStyle(.borderless)
            }
        case .failed:
            Button("Reintentar", action: onRetry).buttonStyle(.borderless)
        default:
            EmptyView()
        }
    }
}
