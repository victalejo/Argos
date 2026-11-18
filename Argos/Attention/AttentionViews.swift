//
//  AttentionViews.swift
//  Argos
//
//  La bandeja de atención en la ventana: botón con el recuento en la barra de
//  herramientas y un popover con la lista agrupada por servidor. Cada fila lleva icono Y
//  texto (nada depende solo del color) y una etiqueta completa para VoiceOver.
//

import SwiftUI

/// Botón de la barra de herramientas: campana con el número de pendientes.
struct AttentionToolbarButton: View {
    let model: ArgosAppModel
    @State private var isPresented = false

    var body: some View {
        let count = model.attentionItems.count
        Button { isPresented.toggle() } label: {
            Label(count > 0 ? "\(count) pendientes" : "Nada pendiente",
                  systemImage: count > 0 ? "bell.badge.fill" : "bell")
                .labelStyle(.titleAndIcon)
        }
        .help("Lo que te necesita en todos los servidores (⌘J va al siguiente)")
        .accessibilityLabel(AttentionText.summary(count: count))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AttentionPopover(model: model) { isPresented = false }
        }
    }
}

/// Lista de la bandeja (popover de la ventana).
struct AttentionPopover: View {
    let model: ArgosAppModel
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AttentionPopoverHeader(count: model.attentionItems.count) {
                onOpen()
                model.openNextAttention()
            }
            Divider()
            AttentionGroupsList(groups: model.attentionGroups) { item in
                onOpen()
                model.openAttention(item)
            }
        }
        .frame(width: 360)
    }
}

private struct AttentionPopoverHeader: View {
    let count: Int
    let onNext: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Te necesita").font(.headline)
                Text(AttentionText.summary(count: count)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ir al siguiente", action: onNext)
                .disabled(count == 0)
                .help("Ir al siguiente que me necesita (⌘J)")
        }
        .padding(14)
    }
}

private struct AttentionGroupsList: View {
    let groups: [AttentionGroup]
    let onOpen: (AttentionItem) -> Void

    var body: some View {
        if groups.isEmpty {
            Text("Nada pendiente. Aquí aparecerá lo que espere tu respuesta en cualquier servidor.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        AttentionGroupSection(group: group, onOpen: onOpen)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 420)
        }
    }
}

private struct AttentionGroupSection: View {
    let group: AttentionGroup
    let onOpen: (AttentionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(group.server.name, systemImage: "server.rack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.items) { item in
                AttentionRow(item: item, serverName: group.server.name) { onOpen(item) }
            }
        }
    }
}

/// Una fila: icono del tipo, qué y dónde.
struct AttentionRow: View {
    let item: AttentionItem
    let serverName: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(item.needsResponse ? Color.orange : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(item.kind.label) · \(item.detail)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel(serverName: serverName))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Abre el proyecto en la ventana de Argos")
    }
}

/// Textos compartidos (ventana, barra de menús, VoiceOver).
enum AttentionText {
    static func summary(count: Int) -> String {
        switch count {
        case 0: return "Nada pendiente"
        case 1: return "1 cosa te necesita"
        default: return "\(count) cosas te necesitan"
        }
    }

    /// Fila del menú de la barra de menús (una línea).
    static func menuTitle(_ item: AttentionItem) -> String {
        "\(item.title) — \(item.kind.label)"
    }
}
