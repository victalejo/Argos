//
//  ImportServerLinkTests.swift
//  ArgosiOSUITests
//
//  «Enviar al iPhone»: el enlace `argos://add-server` (lo que abre la cámara del sistema
//  al escanear el QR del Mac) muestra la confirmación y añade el servidor. No necesita
//  red: el servidor del enlace es ficticio. Deja capturas como adjuntos.
//

import XCTest

final class ImportServerLinkTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Mismo formato que `ServerTransfer.urlString()` (la app no se importa aquí).
    private func transferLink(name: String, createdAt: Date = Date()) throws -> URL {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload: [String: Any] = [
            "v": 1, "n": name, "h": "qr.example.com", "p": 2222, "u": "victor",
            "k": base64URL(Data((0..<32).map { UInt8($0) })),
            "c": "argos-iphone-uitest", "f": "SHA256:uitestfingerprint",
            "t": Int(createdAt.timeIntervalSince1970),
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(URL(string: "argos://add-server?d=\(base64URL(json))"))
    }

    func testEnlaceDelQRMuestraConfirmacionYAnadeServidor() throws {
        let name = "qr-\(Int(Date().timeIntervalSince1970))"
        let app = XCUIApplication()
        app.launch()

        app.open(try transferLink(name: name))

        XCTAssertTrue(app.navigationBars["Añadir desde el Mac"].waitForExistence(timeout: 10),
                      "No se abrió la hoja de importación")
        for text in [name, "victor@qr.example.com:2222", "SHA256:uitestfingerprint"] {
            XCTAssertTrue(shows(text, in: app), "La confirmación no muestra «\(text)»:\n\(app.debugDescription)")
        }
        snapshot("qr-1-confirmacion", app)

        // El "+" de la barra de Servidores también se llama «Añadir servidor».
        app.cells.buttons["Añadir servidor"].tap()
        let row = element(containing: name, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "El servidor no aparece en la lista")
        XCTAssertFalse(app.navigationBars["Añadir desde el Mac"].exists)
        snapshot("qr-2-servidores", app)

        // Limpieza: borra el servidor de prueba.
        row.press(forDuration: 1.2)
        app.buttons["Borrar"].firstMatch.tap()
        app.buttons["Borrar servidor"].firstMatch.tap()
        XCTAssertFalse(element(containing: name, in: app).waitForExistence(timeout: 2))
    }

    func testEnlaceCaducadoAvisa() throws {
        let app = XCUIApplication()
        app.launch()

        app.open(try transferLink(name: "caducado", createdAt: Date().addingTimeInterval(-600)))

        XCTAssertTrue(app.alerts["No se pudo añadir el servidor"].waitForExistence(timeout: 10))
        snapshot("qr-3-caducado", app)
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(element(containing: "caducado", in: app).exists)
    }

    /// ¿Algún elemento visible contiene `text`? (`LabeledContent` puede agrupar etiqueta y
    /// valor en un solo elemento de accesibilidad.)
    private func shows(_ text: String, in app: XCUIApplication) -> Bool {
        element(containing: text, in: app).exists
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch
    }

    private func snapshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
