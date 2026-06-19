//
//  AboutPanel.swift
//  Argos
//
//  Panel nativo "Acerca de Argos": usa el panel estándar de macOS (icono + nombre +
//  versión + copyright del bundle) con un texto de créditos propio y enlaces clicables.
//

import AppKit

enum AboutPanel {
    static let repoURL = URL(string: "https://github.com/victalejo/Argos")!
    static let licenseURL = URL(string: "https://github.com/victalejo/Argos/blob/main/LICENSE")!

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let body = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]

        body.append(NSAttributedString(
            string: "Gestor visual de sesiones tmux remotas vía SSH, nativo de macOS.\n\n",
            attributes: base
        ))
        body.append(link("Repositorio", url: repoURL, paragraph: center))
        body.append(NSAttributedString(string: "   ·   ", attributes: base))
        body.append(link("Licencia Apache-2.0", url: licenseURL, paragraph: center))
        return body
    }

    private static func link(_ text: String, url: URL, paragraph: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .link: url,
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: paragraph,
        ])
    }
}
