//
//  HTMLPreviewPolicyTests.swift
//  ArgosTests
//

import Foundation
import Testing
@testable import Argos

@Suite("Visor HTML: navegación")
struct HTMLPreviewPolicyTests {
    private func decide(_ url: String, link: Bool = false, main: Bool = true, remote: Bool = false) -> HTMLPreviewPolicy.Decision {
        HTMLPreviewPolicy.decide(url: URL(string: url), isUserLink: link, isMainFrame: main, allowsRemoteContent: remote)
    }

    @Test("La carga inicial y las anclas se permiten")
    func initialLoad() {
        #expect(decide("about:blank") == .allow)
        #expect(decide("about:blank#seccion", link: true) == .allow)
    }

    @Test("Los enlaces del usuario se abren fuera solo si son http/https/mailto")
    func userLinks() throws {
        let web = try #require(URL(string: "https://ejemplo.com"))
        #expect(decide("https://ejemplo.com", link: true) == .openExternally(web))
        let mail = try #require(URL(string: "mailto:a@b.co"))
        #expect(decide("mailto:a@b.co", link: true) == .openExternally(mail))
        #expect(decide("file:///etc/passwd", link: true) == .cancel)
        #expect(decide("javascript:alert(1)", link: true) == .cancel)
        #expect(decide("argos://algo", link: true) == .cancel)
    }

    @Test("La página nunca navega sola el documento principal")
    func noAutomaticNavigation() {
        #expect(decide("https://rastreo.com") == .cancel)
        #expect(decide("https://rastreo.com", remote: true) == .cancel)
        #expect(decide("file:///etc/hosts") == .cancel)
        #expect(HTMLPreviewPolicy.decide(url: nil, isUserLink: true, isMainFrame: true, allowsRemoteContent: true) == .cancel)
    }

    @Test("Iframes remotos solo con el contenido externo permitido")
    func iframes() {
        #expect(decide("https://youtube.com/embed/x", main: false) == .cancel)
        #expect(decide("https://youtube.com/embed/x", main: false, remote: true) == .allow)
        #expect(decide("file:///x", main: false, remote: true) == .cancel)
    }

    @Test("El bloqueo de red es JSON válido")
    func rulesAreJSON() throws {
        let data = Data(HTMLPreviewPolicy.blockRemoteRules.utf8)
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rules.count == 2)
    }
}
