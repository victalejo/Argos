//
//  SessionNameSheet.swift
//  Argos
//
//  Sheet único para crear o renombrar una sesión tmux (o renombrar una ventana). Unifica los antiguos
//  CreateSessionSheet y RenameSessionSheet, que eran ~85% código duplicado.
//  Valida en vivo (vacío, ':' '.', caracteres de control, prefijo '-') y muestra
//  los errores del servidor (p. ej. nombre duplicado) en el propio formulario.
//

import SwiftUI

struct SessionNameSheet: View {

    enum Mode: Equatable {
        case create
        case rename(current: String)
        case renameWindow(current: String)

        var title: String {
            switch self {
            case .create: return "Nueva sesión"
            case .rename: return "Renombrar sesión"
            case .renameWindow: return "Renombrar ventana"
            }
        }

        var actionLabel: String {
            switch self {
            case .create: return "Crear"
            case .rename, .renameWindow: return "Renombrar"
            }
        }

        var fieldLabel: String {
            switch self {
            case .create: return "Nombre de la sesión"
            case .rename, .renameWindow: return "Nuevo nombre"
            }
        }

        var initialName: String {
            switch self {
            case .create: return ""
            case .rename(let current), .renameWindow(let current): return current
            }
        }

        var hint: String {
            switch self {
            case .create:
                return "Escribe \"grupo/nombre\" para agruparla, p. ej. \"magic-agents/backend\"."
            case .rename:
                return "Usa \"grupo/nombre\" para moverla de grupo, p. ej. \"magic-agents/backend\"."
            case .renameWindow:
                return "tmux dejará de renombrarla automáticamente según el comando en curso."
            }
        }

        /// Renombrar al mismo nombre sería un no-op: deshabilita el botón.
        func isUnchanged(_ trimmedName: String) -> Bool {
            switch self {
            case .create: return false
            case .rename(let current), .renameWindow(let current): return trimmedName == current
            }
        }

        /// Las ventanas admiten ':' y '.' (se apuntan por índice); las sesiones no.
        func isValid(_ rawName: String) -> Bool {
            switch self {
            case .create, .rename: return SessionNameValidator.isValid(rawName)
            case .renameWindow: return WindowNameValidator.isValid(rawName)
            }
        }

        func liveValidationMessage(for rawName: String) -> String? {
            switch self {
            case .create, .rename: return SessionNameValidator.liveValidationMessage(for: rawName)
            case .renameWindow: return WindowNameValidator.liveValidationMessage(for: rawName)
            }
        }
    }

    let mode: Mode
    /// Valida, ejecuta y refresca. Lanza si el nombre o tmux fallan.
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(mode: Mode, onSubmit: @escaping (String) async throws -> Void) {
        self.mode = mode
        self.onSubmit = onSubmit
        _name = State(initialValue: mode.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title)
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField(mode.fieldLabel, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .disabled(isSubmitting)
                    .onChange(of: name) { errorMessage = nil }

                Text(mode.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = inlineMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(mode.actionLabel, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// El error del servidor (si lo hay) tiene prioridad sobre la validación en vivo.
    private var inlineMessage: String? {
        errorMessage ?? mode.liveValidationMessage(for: name)
    }

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSubmitting
            && mode.isValid(name)
            && !mode.isUnchanged(trimmed)
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(name)
                dismiss()
            } catch {
                errorMessage = error.userMessage
                isSubmitting = false
            }
        }
    }
}

#if DEBUG
#Preview("Crear") {
    SessionNameSheet(mode: .create) { _ in }
}

#Preview("Renombrar") {
    SessionNameSheet(mode: .rename(current: "magic-agents/backend")) { _ in }
}
#endif
