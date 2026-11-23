//
//  MemoryPressureBanner.swift
//  ArgosUI
//
//  Aviso «el servidor se está quedando sin memoria» en la lista de un servidor (Mac e
//  iPhone/iPad). Solo aparece con nivel alto o crítico (`ServerMemoryPressure`).
//

import SwiftUI

struct MemoryPressureBanner: View {
    let pressure: ServerMemoryPressure

    private var tint: Color { pressure.level == .critical ? .red : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: pressure.level == .critical ? "exclamationmark.octagon.fill" : "memorychip")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(pressure.title)
                    .font(.caption.weight(.semibold))
                Text(pressure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Antes de abrir otra sesión con la memoria del servidor en estado crítico, pide
    /// confirmación. `pending` guarda la acción a la espera; nil = sin diálogo.
    func memoryPressureConfirmation(
        _ pending: Binding<MemoryStartConfirmation?>
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { pending.wrappedValue != nil },
            set: { (shown: Bool) in if !shown { pending.wrappedValue = nil } }
        )
        return confirmationDialog(
            pending.wrappedValue?.pressure.title ?? "",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { (confirmation: MemoryStartConfirmation) in
            Button("Iniciar igualmente", role: .destructive) { confirmation.start() }
            Button("Cancelar", role: .cancel) {}
        } message: { (confirmation: MemoryStartConfirmation) in
            Text(confirmation.pressure.message)
        }
    }
}

/// Inicio de sesión a la espera de confirmar por falta de memoria.
struct MemoryStartConfirmation: Identifiable {
    let id = UUID()
    let pressure: ServerMemoryPressure
    let start: () -> Void
}
