//
//  ClaudeLimitsSheet.swift
//  Argos
//
//  Hoja del Mac para activar o quitar la lectura de límites de uso de Claude en un
//  servidor (contenido compartido en `ClaudeLimitsSetupView`).
//

import SwiftUI

struct ClaudeLimitsSheet: View {
    let target: ServerSheetTarget
    let model: ArgosAppModel
    let onClose: () -> Void

    @State private var setup: ClaudeLimitsSetupModel

    init(target: ServerSheetTarget, model: ArgosAppModel, onClose: @escaping () -> Void) {
        self.target = target
        self.model = model
        self.onClose = onClose
        _setup = State(initialValue: ClaudeLimitsSetupModel(service: target.service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Límites de Claude").font(.title2.weight(.semibold))
            ScrollView {
                ClaudeLimitsSetupView(
                    model: setup,
                    status: model.vms[target.server.id]?.claudeLimits,
                    serverName: target.server.name
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Listo", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }
}
