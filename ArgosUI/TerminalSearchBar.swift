//
//  TerminalSearchBar.swift
//  ArgosUI
//
//  Barra «Buscar en el historial» sobre el terminal (Mac e iPhone/iPad): campo, contador
//  («3 de 12»), siguiente/anterior, opciones (mayúsculas, expresión regular, todas las
//  ventanas), copiar coincidencias y cerrar (Esc). La búsqueda la hace tmux; el estado
//  vive en `TerminalSearchModel`. El portapapeles lo pone cada plataforma (`copy`).
//

import SwiftUI

struct TerminalSearchBar: View {
    @Bindable var model: TerminalSearchModel
    /// Copia al portapapeles de la plataforma.
    let copy: (String) -> Void
    /// Tras cerrar (Esc o la «×»): devolver el foco al terminal.
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            if model.options.allWindows && !model.windowResults.isEmpty {
                Divider()
                TerminalWindowResultsList(model: model)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .onAppear { fieldFocused = true }
        // Si el foco vuelve al terminal (un clic o un toque en él), lo que se teclee iría al
        // modo copia de tmux: la búsqueda se cierra.
        .onChange(of: fieldFocused) { (wasFocused: Bool, isFocused: Bool) in
            if wasFocused && !isFocused && model.isPresented { model.dismiss() }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            field
            counter
            stepButtons
            optionsMenu
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Cerrar (Esc)")
            .accessibilityLabel("Cerrar la búsqueda")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var field: some View {
        TextField("Buscar en el historial", text: $model.query)
            .textFieldStyle(.plain)
            .focused($fieldFocused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            #endif
            .onSubmit { model.next() }
            .onKeyPress(.escape) {
                close()
                return .handled
            }
            .frame(minWidth: 80)
    }

    @ViewBuilder
    private var counter: some View {
        if let text = model.statusText {
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isProblem ? Color.red : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(failureDetail ?? "")
        }
    }

    private var isProblem: Bool {
        switch model.status {
        case .invalidPattern, .failed: return true
        default: return false
        }
    }

    private var failureDetail: String? {
        if case .failed(let message) = model.status { return message }
        return nil
    }

    private var stepButtons: some View {
        HStack(spacing: 2) {
            Button { model.next() } label: { Image(systemName: "chevron.up") }
                .help("Coincidencia anterior en el historial (⌘G)")
                .accessibilityLabel("Más antigua")
            Button { model.previous() } label: { Image(systemName: "chevron.down") }
                .help("Coincidencia más reciente (⇧⌘G)")
                .accessibilityLabel("Más reciente")
        }
        .buttonStyle(.borderless)
        // Los botones no se llevan el foco del campo (perderlo cierra la búsqueda).
        .focusable(false)
        .disabled(!model.canStep)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Distinguir mayúsculas", isOn: $model.options.caseSensitive)
            Toggle("Expresión regular", isOn: $model.options.regex)
            Toggle("Todas las ventanas", isOn: $model.options.allWindows)
            Divider()
            Button("Copiar coincidencias", systemImage: "doc.on.doc", action: copyMatches)
                .disabled(model.pattern == nil)
        } label: {
            Image(systemName: hasOptions ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help("Opciones de búsqueda")
        .accessibilityLabel("Opciones de búsqueda")
    }

    private var hasOptions: Bool {
        model.options.caseSensitive || model.options.regex || model.options.allWindows
    }

    private func copyMatches() {
        Task {
            if let text = await model.matchingText() { copy(text) }
        }
    }

    private func close() {
        model.dismiss()
        onClose()
    }
}

/// Resultados de «Todas las ventanas»: por ventana, las líneas con coincidencias (las más
/// recientes primero). Al tocar una, se cambia a esa ventana y se salta a ella.
struct TerminalWindowResultsList: View {
    let model: TerminalSearchModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.windowResults) { (result: TerminalWindowSearchResult) in
                    section(result)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 260)
    }

    private func section(_ result: TerminalWindowSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Ventana \(result.windowIndex): \(result.windowName) · \(result.matchCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(result.lines) { (line: TerminalWindowSearchLine) in
                row(line, in: result)
            }
        }
    }

    private func row(_ line: TerminalWindowSearchLine, in result: TerminalWindowSearchResult) -> some View {
        Button { model.open(line, in: result) } label: {
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Aviso breve sobre el terminal («Copiadas 12 líneas», o el fallo).
struct TerminalNoticeCapsule: View {
    let message: String
    let isError: Bool

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(isError ? Color.orange : Color.green)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .multilineTextAlignment(.leading)
            .accessibilityElement(children: .combine)
    }
}
