//
//  AttentionMenuBarExtra.swift
//  Argos
//
//  Extra de la barra de menús: campana con el número de pendientes y la lista agrupada
//  por servidor. Elegir un elemento abre la ventana en ese proyecto y ventana (también con
//  la ventana cerrada). Se oculta en Ajustes → Avisos o desde el propio menú.
//

import SwiftUI

/// Icono del extra.
struct AttentionMenuBarLabel: View {
    let model: ArgosAppModel

    var body: some View {
        let count = model.attentionItems.count
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
            if count > 0 { Text("\(count)") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Argos: \(AttentionText.summary(count: count))")
    }
}

/// Menú del extra.
struct AttentionMenuContent: View {
    let model: ArgosAppModel
    @AppStorage(AttentionSettings.showsMenuBarExtraKey) private var showsMenuBarExtra = true

    var body: some View {
        AttentionMenuItems(model: model)
        Divider()
        Button("Ir al siguiente que me necesita") { model.openNextAttention() }
            .disabled(model.attentionItems.isEmpty)
        Button("Mostrar la ventana de Argos") { model.showMainWindow() }
        Divider()
        Button("Ocultar de la barra de menús") { showsMenuBarExtra = false }
        Button("Salir de Argos") { NSApp.terminate(nil) }
    }
}

private struct AttentionMenuItems: View {
    let model: ArgosAppModel

    var body: some View {
        let groups = model.attentionGroups
        if groups.isEmpty {
            Text("Nada pendiente")
        }
        ForEach(groups) { group in
            Section(group.server.name) {
                ForEach(group.items) { item in
                    AttentionMenuItem(item: item, serverName: group.server.name) { model.openAttention(item) }
                }
            }
        }
    }
}

private struct AttentionMenuItem: View {
    let item: AttentionItem
    let serverName: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label(AttentionText.menuTitle(item), systemImage: item.kind.systemImage)
        }
        .help(item.detail)
        .accessibilityLabel(item.accessibilityLabel(serverName: serverName))
    }
}

/// Ajustes → Avisos.
struct AttentionSettingsView: View {
    @AppStorage(AttentionSettings.showsMenuBarExtraKey) private var showsMenuBarExtra = true
    @AppStorage(AttentionSettings.showsDockBadgeKey) private var showsDockBadge = true

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar en la barra de menús", isOn: $showsMenuBarExtra)
                Text("Una campana con lo que te necesita en todos los servidores, también con la ventana cerrada.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Número en el icono del Dock", isOn: $showsDockBadge)
                    .onChange(of: showsDockBadge) {
                        NotificationCenter.default.post(name: AttentionSettings.didChange, object: nil)
                    }
                Text("Cuenta solo lo que espera tu respuesta: Claude esperando, permisos del agente y puertos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
