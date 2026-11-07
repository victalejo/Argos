//
//  MarkdownText.swift
//  ArgosiOS
//
//  Markdown seguro (versión iOS de `SafeMarkdownView`): no carga imágenes remotas
//  (un README o una respuesta del agente podrían rastrear al usuario) y los enlaces
//  solo se abren si son http(s)/mailto, tras confirmar la URL completa.
//

import MarkdownUI
import SwiftUI

struct MarkdownText: View {
    enum Style { case document, chat }

    let text: String
    var style: Style = .chat

    @State private var pendingLink: URL?

    var body: some View {
        Markdown(text)
            .markdownTheme(style == .document ? .gitHub : .basic)
            .markdownImageProvider(BlockedImageProvider())
            .markdownInlineImageProvider(BlockedInlineImageProvider())
            .environment(\.openURL, OpenURLAction { url in
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { pendingLink = url }
                return .handled
            })
            .alert("¿Abrir este enlace?", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } })) {
                Button("Abrir") { if let pendingLink { UIApplication.shared.open(pendingLink) } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(pendingLink?.absoluteString ?? "")
            }
    }
}

private struct BlockedImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Label("Imagen no cargada", systemImage: "photo")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct BlockedInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "photo")
    }
}
