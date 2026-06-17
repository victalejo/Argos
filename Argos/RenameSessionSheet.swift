//
//  RenameSessionSheet.swift
//  Argos
//
//  Fase 3: sheet para renombrar una sesión tmux. Se prellena con el nombre actual.
//  Misma validación en vivo que al crear; cambiar el prefijo "grupo/" mueve la sesión
//  de grupo. El botón se deshabilita si el nombre es inválido o no ha cambiado.
//

import SwiftUI

struct RenameSessionSheet: View {
    let session: TmuxSession
    /// Valida, renombra y refresca la lista. Lanza si el nombre o tmux fallan.
    let onRename: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(session: TmuxSession, onRename: @escaping (String) async throws -> Void) {
        self.session = session
        self.onRename = onRename
        _newName = State(initialValue: session.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Renombrar sesión")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField("Nuevo nombre", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .disabled(isSubmitting)
                    .onChange(of: newName) { errorMessage = nil }

                Text("Usa \"grupo/nombre\" para moverla de grupo, p. ej. \"magic-agents/backend\".")
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
                Button("Renombrar", action: submit)
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
        errorMessage ?? SessionNameValidator.liveValidationMessage(for: newName)
    }

    /// El nombre normalizado coincide con el actual: renombrar sería un no-op.
    private var isUnchanged: Bool {
        newName.trimmingCharacters(in: .whitespacesAndNewlines) == session.name
    }

    private var canSubmit: Bool {
        !isSubmitting && SessionNameValidator.isValid(newName) && !isUnchanged
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onRename(newName)
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
#Preview("Renombrar") {
    RenameSessionSheet(
        session: TmuxSession(name: "magic-agents/backend",
                             windowCount: 2, isAttached: false, createdAt: .now)
    ) { _ in }
}
#endif
