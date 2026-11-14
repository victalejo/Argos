//
//  HTMLDocumentView.swift
//  Argos
//
//  Visor HTML del explorador de archivos (macOS). La seguridad (sin JS ni red por
//  defecto, sin navegación) la aplica `HTMLPreviewController`; aquí los enlaces se
//  abren en el navegador tras confirmar con `SafeLinkPolicy`.
//

import SwiftUI
import WebKit

struct HTMLDocumentView: NSViewRepresentable {
    let html: String
    let allowsRemoteContent: Bool

    func makeCoordinator() -> HTMLPreviewController {
        HTMLPreviewController { url in
            if SafeLinkPolicy.confirm(url) { NSWorkspace.shared.open(url) }
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(html: html, allowsRemoteContent: allowsRemoteContent)
    }
}
