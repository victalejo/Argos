//
//  PromptConfirmationView.swift
//  ArgosUI
//
//  Hoja de confirmación de la biblioteca de encargos (Mac e iPhone/iPad): antes de pegar o
//  encolar un prompt con variables se enseña el texto exacto, ya relleno con lo que dijo
//  git en el servidor (rama, commit, archivos), para que nada llegue a Claude sin verlo.
//

import SwiftUI

struct PromptConfirmationView: View {
    let model: PromptLibraryModel
    let pending: PendingPromptUse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revisa el encargo antes de enviarlo").font(.headline)
            Text("Los valores entre « » vienen de git en el servidor.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            preview
            buttons
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 300)
    }

    private var preview: some View {
        ScrollView {
            Text(verbatim: pending.text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityLabel(Text("Texto que se enviará"))
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancelar") { cancel() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) { confirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private var confirmTitle: LocalizedStringKey {
        pending.kind == .send ? "Enviar a la terminal" : "Añadir a la cola"
    }

    private func cancel() {
        model.cancelPendingUse()
        dismiss()
    }

    private func confirm() {
        dismiss()
        Task { await model.confirmPendingUse() }
    }
}
