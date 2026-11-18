//
//  PortRequestAlert.swift
//  Argos
//
//  Aviso «Claude quiere mostrarte el puerto N» de CUALQUIER servidor conectado (antes
//  solo se vigilaban con un proyecto de ese servidor a la vista). Las solicitudes las lee
//  el sondeador agrupado (`WorkspacePoller`); aquí solo se muestran y se responden.
//

import SwiftUI

private struct PortRequestAlert: ViewModifier {
    let model: ArgosAppModel
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let pending = model.pendingPortRequest
        content
            .alert(
                pending.map { PortForwardRequestsModel.title(for: $0.request) } ?? "",
                // Con el popover de «Puertos» abierto, espera (no se pinta encima).
                isPresented: Binding(
                    get: { model.pendingPortRequest != nil && !PortForwardsUIState.shared.isPopoverOpen },
                    set: { _ in }
                ),
                presenting: pending
            ) { pending in
                Button("Abrir") {
                    Task {
                        if let url = await pending.model.accept() { openURL(url) }
                        PortForwardsUIState.shared.tunnelsChanged()
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Ahora no", role: .cancel) { Task { await pending.model.decline() } }
            } message: { pending in
                Text(verbatim: PortForwardRequestPrompt.message(for: pending.request, serverName: pending.server.name))
            }
            .alert("No se pudo abrir el puerto", isPresented: errorBinding) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(failingModel?.errorMessage ?? "")
            }
    }

    private var failingModel: PortForwardRequestsModel? {
        model.store.servers.compactMap { model.portRequests[$0.id] }.first { $0.errorMessage != nil }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { failingModel != nil },
            set: { if !$0 { failingModel?.errorMessage = nil } }
        )
    }
}

extension View {
    /// Muestra las solicitudes de puertos de Claude de todos los servidores.
    func portRequestAlerts(_ model: ArgosAppModel) -> some View {
        modifier(PortRequestAlert(model: model))
    }
}
