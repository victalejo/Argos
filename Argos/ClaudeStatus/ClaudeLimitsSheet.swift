//
//  ClaudeLimitsSheet.swift
//  Argos
//
//  Hoja del Mac «Uso y límites de Claude» de un servidor: tokens y coste por proyecto y día
//  (`ClaudeUsageView`), la lectura de límites (`ClaudeLimitsSetupView`) y el contexto que
//  Argos le da a Claude al arrancar (`SessionContextSettingsView`).
//

import SwiftUI

struct ClaudeLimitsSheet: View {
    let target: ServerSheetTarget
    let model: ArgosAppModel
    let onClose: () -> Void

    @State private var setup: ClaudeLimitsSetupModel
    @State private var usage: ClaudeUsageModel
    @State private var context: SessionContextModel

    init(target: ServerSheetTarget, model: ArgosAppModel, onClose: @escaping () -> Void) {
        self.target = target
        self.model = model
        self.onClose = onClose
        _setup = State(initialValue: ClaudeLimitsSetupModel(service: target.service))
        _context = State(initialValue: SessionContextModel(service: target.service))
        _usage = State(initialValue: ClaudeUsageModel(
            service: target.service, projects: model.vms[target.server.id]?.projects ?? []
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uso y límites de Claude").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Uso") { ClaudeUsageView(model: usage) }
                    section("Límites de la suscripción") {
                        ClaudeLimitsSetupView(
                            model: setup,
                            status: model.vms[target.server.id]?.claudeLimits,
                            serverName: target.server.name
                        )
                    }
                    section("Contexto al arrancar Claude") {
                        SessionContextSettingsView(model: context, projects: model.vms[target.server.id]?.projects ?? [], serverID: target.server.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Listo", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 640)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}
