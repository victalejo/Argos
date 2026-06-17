//
//  CreateSessionSheet.swift
//  Argos
//
//  Fase 3: sheet para crear una sesión tmux. Un único TextField + sugerencia de
//  agrupamiento ("grupo/nombre"). Valida en vivo (vacío, ':' y '.') y muestra los
//  errores del servidor (p. ej. nombre duplicado) en el propio formulario.
//

import SwiftUI

struct CreateSessionSheet: View {
    /// Valida, crea la sesión y refresca la lista. Lanza si el nombre o tmux fallan.
    let onCreate: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nueva sesión")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField("Nombre de la sesión", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .disabled(isSubmitting)
                    .onChange(of: name) { errorMessage = nil }

                Text("Escribe \"grupo/nombre\" para agruparla, p. ej. \"magic-agents/backend\".")
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
                Button("Crear", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// El error del servidor (si lo hay) tiene prioridad sobre el de validación en vivo.
    private var inlineMessage: String? {
        errorMessage ?? SessionNameValidator.liveValidationMessage(for: name)
    }

    private var canSubmit: Bool {
        !isSubmitting && SessionNameValidator.isValid(name)
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onCreate(name)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

#if DEBUG
#Preview("Crear") {
    CreateSessionSheet { _ in }
}
#endif
