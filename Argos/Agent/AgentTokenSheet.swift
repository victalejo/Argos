//
//  AgentTokenSheet.swift
//  Argos
//
//  Token de suscripción de Claude (avanzado): alternativa a iniciar sesión en el servidor.
//

import SwiftUI

struct AgentTokenSheet: View {
    let onClose: () -> Void
    @State private var token = ""
    @State private var hasToken = KeychainStore.hasClaudeOAuthToken()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token de suscripción").font(.title3.weight(.semibold))
            Text("Alternativa a conectar el servidor: genera un token en tu Mac con `claude setup-token` "
                 + "y pégalo aquí. Se guarda en el Llavero y usa tu plan, nunca la API de pago.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hasToken {
                HStack {
                    Label("Hay un token guardado", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Quitar", role: .destructive) {
                        KeychainStore.deleteClaudeOAuthToken()
                        hasToken = false
                    }
                }
            } else {
                SecureField("Token (claude setup-token)", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cerrar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                if !hasToken {
                    Button("Guardar") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        do {
            try KeychainStore.setClaudeOAuthToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            onClose()
        } catch {
            self.error = error.userMessage
        }
    }
}
