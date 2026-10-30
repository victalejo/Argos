//
//  SafeMarkdownView.swift
//  Argos
//
//  Markdown renderizado (swift-markdown-ui) para contenido NO confiable (archivos del
//  servidor, respuestas del agente):
//   - NUNCA carga imágenes remotas (evita píxeles de rastreo y filtrar tu IP): se
//     muestra un marcador con la URL en su lugar.
//   - Los enlaces solo se abren si son http/https/mailto Y tras confirmarlo, mostrando
//     la URL real. Cualquier otro esquema (file:, esquemas de apps…) se descarta.
//

import AppKit
import MarkdownUI
import SwiftUI

struct SafeMarkdownView: View {
    enum Style {
        /// Documento (README…): tema GitHub.
        case document
        /// Respuestas del agente: tema básico, sin fondo propio (va dentro del chat).
        case chat
    }

    let text: String
    var style: Style = .document

    var body: some View {
        Markdown(text)
            .markdownTheme(style == .document ? .gitHub : .basic)
            .markdownImageProvider(BlockedImageProvider())
            .markdownInlineImageProvider(BlockedInlineImageProvider())
            .environment(\.openURL, OpenURLAction { url in
                SafeLinkPolicy.isAllowed(url) && SafeLinkPolicy.confirm(url) ? .systemAction : .discarded
            })
    }
}

/// Qué enlaces se pueden abrir (lógica pura, testeable).
enum SafeLinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Pide confirmación mostrando la URL completa (el texto del enlace puede engañar).
    @MainActor
    static func confirm(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "¿Abrir este enlace?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Abrir")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Sustituye cada imagen por un marcador (sin red).
private struct BlockedImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Label {
            Text("Imagen no cargada" + (url.map { ": \($0.absoluteString)" } ?? ""))
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "photo")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .help("Las imágenes de documentos no se descargan para no revelar tu IP ni permitir rastreo.")
    }
}

/// Las imágenes en línea no se cargan (se omiten).
private struct BlockedInlineImageProvider: InlineImageProvider {
    struct Blocked: Error {}
    func image(with url: URL, label: String) async throws -> Image { throw Blocked() }
}
