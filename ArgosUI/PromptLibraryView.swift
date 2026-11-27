//
//  PromptLibraryView.swift
//  ArgosUI
//
//  Biblioteca de encargos de un proyecto (Mac e iPhone/iPad): los prompts del proyecto y
//  los comunes del servidor, con crear, editar, borrar, reordenar (arrastrando) y usarlos
//  ya: pegarlos en la terminal o añadirlos a la cola de encargos.
//

import SwiftUI

struct PromptLibraryView: View {
    @Bindable var model: PromptLibraryModel

    var body: some View {
        List {
            Section { intro }
            if let notice = model.notice { Section { Text(notice).font(.callout) } }
            if let error = model.errorMessage {
                Section { Text(error).font(.callout).foregroundStyle(.red) }
            }
            section("Este proyecto", scope: .project(model.project.id), prompts: model.projectPrompts)
            section("Comunes del servidor", scope: .common, prompts: model.commonPrompts)
        }
        .disabled(model.isLoading)
        .overlay { if model.isLoading { ProgressView() } }
        .task { await model.load() }
        .sheet(item: $model.editing) { (prompt: SavedPrompt) in
            PromptEditorView(model: model, prompt: prompt)
        }
        // En otra vista que la del editor: dos `.sheet` en la misma no se llevan bien.
        .background {
            Color.clear.sheet(item: $model.pendingUse) { (pending: PendingPromptUse) in
                PromptConfirmationView(model: model, pending: pending)
            }
        }
    }

    private var intro: some View {
        Text("Al enviarlo se rellenan {rama}, {ultimo_commit}, {archivos_cambiados} y {fecha} con lo que diga git en la carpeta del proyecto. Se guardan en el servidor: los ven también tus otros dispositivos.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section(_ title: LocalizedStringKey, scope: PromptScope, prompts: [SavedPrompt]) -> some View {
        Section {
            ForEach(prompts) { (prompt: SavedPrompt) in
                PromptLibraryRow(model: model, prompt: prompt, scope: scope)
                    // Mientras se guarda un cambio no se puede mover ni borrar otra fila:
                    // `perform` lo ignoraría y la lista volvería sola a su sitio.
                    .moveDisabled(model.isWorking)
                    .deleteDisabled(model.isWorking)
            }
            .onMove { (source: IndexSet, destination: Int) in
                Task { await model.move(scope: scope, from: source, to: destination) }
            }
            .onDelete { (offsets: IndexSet) in
                let doomed = offsets.map { prompts[$0] }
                Task { for prompt in doomed { await model.delete(prompt, scope: scope) } }
            }
            Button {
                model.startNew(scope: scope)
            } label: {
                Label("Nuevo encargo", systemImage: "plus")
            }
            .disabled(model.isWorking)
        } header: {
            Text(title)
        }
    }
}

private struct PromptLibraryRow: View {
    let model: PromptLibraryModel
    let prompt: SavedPrompt
    let scope: PromptScope

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.displayTitle).font(.callout.weight(.medium))
                Text(prompt.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            actions
        }
    }

    private var actions: some View {
        Menu {
            Button("Enviar ya a la terminal", systemImage: "terminal") {
                Task { await model.sendToTerminal(prompt) }
            }
            Button("Añadir a la cola de encargos", systemImage: "text.badge.plus") {
                Task { await model.enqueue(prompt) }
            }
            Divider()
            Button("Editar", systemImage: "pencil") { model.startEditing(prompt, scope: scope) }
            Button("Borrar", systemImage: "trash", role: .destructive) {
                Task { await model.delete(prompt, scope: scope) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(model.isWorking)
        .accessibilityLabel(Text("Acciones de «\(prompt.displayTitle)»"))
    }
}

/// Formulario de un prompt (nuevo o existente).
private struct PromptEditorView: View {
    let model: PromptLibraryModel
    @State private var draft: SavedPrompt
    @Environment(\.dismiss) private var dismiss

    init(model: PromptLibraryModel, prompt: SavedPrompt) {
        self.model = model
        _draft = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.editingScope == .common ? "Encargo común del servidor" : "Encargo de este proyecto")
                .font(.headline)
            TextField("Título", text: $draft.title)
            TextEditor(text: $draft.text)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .accessibilityLabel(Text("Texto del encargo"))
            PromptRunOptions(model: $draft.model, effort: $draft.effort)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Guardar") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!PromptLibraryModel.canSave(draft) || model.isWorking)
        }
    }

    private func save() {
        model.editing = draft
        Task { await model.saveEditing() }
    }
}

/// Modelo y esfuerzo opcionales de un prompt («Haiku para lo mecánico»).
private struct PromptRunOptions: View {
    @Binding var model: SavedPrompt.Model?
    @Binding var effort: SavedPrompt.Effort?

    var body: some View {
        HStack(spacing: 16) {
            Picker("Modelo", selection: $model) {
                Text("Sin preferencia").tag(SavedPrompt.Model?.none)
                ForEach(SavedPrompt.Model.allCases, id: \.self) { (option: SavedPrompt.Model) in
                    Text(verbatim: Self.name(option)).tag(SavedPrompt.Model?.some(option))
                }
            }
            Picker("Esfuerzo", selection: $effort) {
                Text("Sin preferencia").tag(SavedPrompt.Effort?.none)
                ForEach(SavedPrompt.Effort.allCases, id: \.self) { (option: SavedPrompt.Effort) in
                    Text(Self.name(option)).tag(SavedPrompt.Effort?.some(option))
                }
            }
        }
    }

    /// Nombres de producto: no se traducen.
    static func name(_ model: SavedPrompt.Model) -> String {
        switch model {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }

    static func name(_ effort: SavedPrompt.Effort) -> String {
        switch effort {
        case .low: return String(localized: "Bajo")
        case .medium: return String(localized: "Medio")
        case .high: return String(localized: "Alto")
        case .max: return String(localized: "Máximo")
        }
    }
}
