//
//  DemoServerFlowTests.swift
//  ArgosiOSUITests
//
//  Prueba de extremo a extremo de la app de iPhone contra un servidor REAL: alta del
//  servidor (con «Probar conexión»), lista de proyectos, terminal en vivo, escritura en
//  la sesión tmux y vuelta desde segundo plano. Deja capturas como adjuntos.
//
//  Necesita la cuenta de demostración en el entorno del runner (si falta, se salta):
//    TEST_RUNNER_ARGOS_DEMO_HOST=190.102.110.8 TEST_RUNNER_ARGOS_DEMO_PORT=2222 \
//    TEST_RUNNER_ARGOS_DEMO_USER=argos-demo TEST_RUNNER_ARGOS_DEMO_PASSWORD=… \
//    xcodebuild test -scheme ArgosiOS -destination 'platform=iOS Simulator,name=…'
//
//  El marcador que escribe en el terminal (ARGOS_DEMO_MARKER) permite comprobar desde
//  fuera, con `tmux capture-pane`, que las teclas llegaron de verdad al servidor.
//

import XCTest

final class DemoServerFlowTests: XCTestCase {

    private struct Demo {
        let host: String
        let port: String
        let user: String
        let password: String
        let marker: String
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func demoAccount() throws -> Demo {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["ARGOS_DEMO_HOST"], let password = env["ARGOS_DEMO_PASSWORD"] else {
            throw XCTSkip("Sin ARGOS_DEMO_HOST / ARGOS_DEMO_PASSWORD: prueba contra servidor real omitida.")
        }
        return Demo(
            host: host,
            port: env["ARGOS_DEMO_PORT"] ?? "22",
            user: env["ARGOS_DEMO_USER"] ?? "argos-demo",
            password: password,
            marker: env["ARGOS_DEMO_MARKER"] ?? "hola-desde-iphone"
        )
    }

    func testAltaProyectosTerminalYSegundoPlano() throws {
        let demo = try demoAccount()
        app = XCUIApplication()
        app.launch()

        addServerIfNeeded(demo)
        snapshot("1-servidores")

        // Proyectos del servidor (los mismos que ve Argos en el Mac).
        app.staticTexts["demo"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["tienda-online"].waitForExistence(timeout: 30), "No cargó la lista de proyectos")
        XCTAssertTrue(app.staticTexts["backups"].exists)
        snapshot("2-proyectos")

        // Terminal en vivo de un proyecto en marcha.
        app.staticTexts["tienda-online"].tap()
        XCTAssertTrue(app.navigationBars["web/tienda-online"].waitForExistence(timeout: 15))
        sleep(4)
        snapshot("3-terminal")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Escribir en una sesión con shell y comprobar que llega al servidor.
        app.staticTexts["backups"].tap()
        XCTAssertTrue(app.navigationBars["backups"].waitForExistence(timeout: 15))
        sleep(3)
        app.typeText("clear; echo \(demo.marker)-1\n")
        sleep(2)
        snapshot("4-escritura")

        // Segundo plano y vuelta: el PTY se reabre y se puede seguir escribiendo.
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        sleep(5)
        app.typeText("echo \(demo.marker)-2\n")
        sleep(2)
        snapshot("5-tras-segundo-plano")
    }

    // MARK: - Pasos

    private func addServerIfNeeded(_ demo: Demo) {
        if app.staticTexts["demo"].waitForExistence(timeout: 3) { return }

        app.navigationBars.buttons["Añadir servidor"].tap()
        fill("Nombre (p. ej. producción)", with: "demo")
        fill("Host o IP", with: demo.host)
        let port = app.textFields["Puerto"]
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + demo.port)
        fill("Usuario", with: demo.user)
        let password = app.secureTextFields["Contraseña"]
        password.tap()
        password.typeText(demo.password)

        app.buttons["Probar conexión"].tap()
        let ok = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Conectado como")).firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 30), "La prueba de conexión no tuvo éxito")
        snapshot("0-formulario")

        app.navigationBars.buttons["Guardar"].tap()
        dismissSavePasswordPrompt()
        XCTAssertTrue(app.staticTexts["demo"].waitForExistence(timeout: 5))
    }

    /// iOS ofrece guardar la contraseña en el Llavero de iCloud. El diálogo lo pinta un
    /// servicio remoto que no aparece en el árbol de accesibilidad: se toca «Ahora no»
    /// por coordenadas (zona vacía de la lista si el diálogo no aparece).
    private func dismissSavePasswordPrompt() {
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.625)).tap()
        sleep(1)
    }

    private func fill(_ placeholder: String, with text: String) {
        let field = app.textFields[placeholder]
        field.tap()
        field.typeText(text)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
