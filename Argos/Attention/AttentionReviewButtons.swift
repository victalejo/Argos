//
//  AttentionReviewButtons.swift
//  Argos
//
//  Las dos salidas de un encargo bloqueado por el revisor, bajo su fila de la bandeja.
//

import SwiftUI

struct AttentionReviewButtons: View {
    let onAction: (AttentionReviewAction) -> Void

    @State private var confirmsPush = false
    /// Tras elegir, los botones se apagan (la fila desaparece al resolverse).
    @State private var chosen = false

    var body: some View {
        HStack(spacing: 8) {
            Button("Pedir a Claude que lo arregle") { choose(.requestFix) }
                .buttonStyle(.borderedProminent)
            Button("Subir igualmente") { confirmsPush = true }
                .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .disabled(chosen)
        .padding(.leading, 28)
        .confirmationDialog("¿Subir sin la aprobación del revisor?", isPresented: $confirmsPush, titleVisibility: .visible) {
            Button("Subir igualmente", role: .destructive) { choose(.pushAnyway) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se hará el push que faltaba tal como está el commit, con los hallazgos sin corregir.")
        }
    }

    private func choose(_ action: AttentionReviewAction) {
        guard !chosen else { return }
        chosen = true
        onAction(action)
    }
}
