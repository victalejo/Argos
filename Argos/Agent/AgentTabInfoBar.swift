//
//  AgentTabInfoBar.swift
//  Argos
//
//  Franja sobre la conversación que dice DÓNDE vive y qué pasa al cerrarla:
//   - De esta sesión: se detiene al cerrar la pestaña o salir. «Continuar en el servidor».
//   - Persistente: sigue en el servidor aunque se cierre la pestaña o Argos. «Poner en
//     reposo», «Detener» y «Reanudar» son acciones explícitas.
//

import SwiftUI

struct AgentTabInfoBar: View {
    enum Action {
        case continueOnServer
        case hibernate
        case stop
        case resume
        case reload
    }

    let slot: AgentTabSlot
    let isConverting: Bool
    let perform: (Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(summary, systemImage: slot.lifecycle == .persistent ? "server.rack" : "laptopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            switch slot {
            case .session(let tab): sessionActions(tab)
            case .persistent(let tab): persistentActions(tab)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    private var summary: String {
        switch slot {
        case .session:
            return String(localized: "Solo en esta sesión: se detiene al cerrar la pestaña o salir de Argos.")
        case .persistent:
            return String(localized: "En el servidor: sigue aunque cierres la pestaña o Argos. Puedes continuarla desde el iPhone.")
        }
    }

    @ViewBuilder
    private func sessionActions(_ tab: AgentTab) -> some View {
        let blocker = AgentConversion.blocker(
            hasConversation: tab.session.hasConversation, isBusy: tab.session.isBusy, sessionID: tab.session.sessionID
        )
        if isConverting {
            ProgressView().controlSize(.mini)
            Text("Pasando al servidor…").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Continuar en el servidor", systemImage: "arrow.up.to.line") { perform(.continueOnServer) }
                .disabled(blocker != nil)
                .help(blocker?.errorDescription
                      ?? String(localized: "Detiene esta conversación aquí y la relanza en el servidor (--resume): sigue aunque cierres Argos y puedes continuarla desde el iPhone."))
        }
    }

    @ViewBuilder
    private func persistentActions(_ tab: PersistentAgentTab) -> some View {
        let session = tab.session
        if session.isAlive {
            Button("Poner en reposo", systemImage: "moon.zzz") { perform(.hibernate) }
                .disabled(session.phase.isBusy)
                .help("Para el proceso si Claude está quieto; escribirle lo reanuda con la misma conversación.")
            Button("Detener", systemImage: "stop.circle", role: .destructive) { perform(.stop) }
                .help("Detiene el agente en el servidor. La conversación se puede reanudar después.")
        } else if !session.meta.isHibernated {
            Button("Reanudar", systemImage: "play.circle") { perform(.resume) }
                .disabled(session.isResuming)
                .help("Vuelve a arrancar el agente en el servidor con la misma conversación (--resume).")
        }
        Button("Recargar", systemImage: "arrow.clockwise") { perform(.reload) }
            .labelStyle(.iconOnly)
            .help("Volver a leer la conversación desde el servidor")
    }
}
