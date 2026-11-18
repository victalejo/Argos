//
//  LocalizationEnglishTests.swift
//  ArgosTests
//
//  Un puñado de mensajes clave evaluados con la localización INGLESA del bundle de la
//  app (los tests corren en español). Cada test comprueba además que el código produce
//  la clave en español esperada, así que si alguien cambia el texto del código sin
//  actualizar el catálogo, falla aquí.
//

import Foundation
import Testing
@testable import Argos

@Suite("Localización: inglés")
struct LocalizationEnglishTests {

    private func english(_ key: String, _ arguments: CVarArg...) -> String {
        let format = LocalizationSupport.englishBundle?.localizedString(forKey: key, value: "⟨sin traducir⟩", table: nil) ?? "⟨sin bundle⟩"
        return String(format: format, locale: Locale(identifier: "en_US"), arguments: arguments)
    }

    @Test("el bundle de la app trae la localización inglesa")
    func englishBundleExists() {
        #expect(LocalizationSupport.englishBundle != nil)
    }

    // MARK: - Errores de conexión

    @Test("conexión rechazada")
    func connectionRefused() {
        let spanish = SSHErrorMessage.connectionFailure(host: "srv", port: 2222, dnsFailed: false, refused: true)
        #expect(spanish == "srv rechazó la conexión en el puerto 2222. Comprueba el puerto y que el servicio SSH esté en marcha.")
        // El puerto es un identificador: va como texto (con %lld saldría «2,222» en inglés).
        let key = "%@ rechazó la conexión en el puerto %@. Comprueba el puerto y que el servicio SSH esté en marcha."
        #expect(english(key, "srv", "2222") == "srv refused the connection on port 2222. Check the port and that the SSH service is running.")
    }

    @Test("servidor no encontrado y credenciales rechazadas")
    func connectionErrors() {
        let dns = SSHErrorMessage.connectionFailure(host: "ejemplo.com", port: 22, dnsFailed: true, refused: false)
        #expect(dns == "No se encontró el servidor «ejemplo.com». Revisa la dirección y tu conexión a internet.")
        #expect(english("No se encontró el servidor «%@». Revisa la dirección y tu conexión a internet.", "example.com")
                == "The server “example.com” wasn’t found. Check the address and your internet connection.")
        #expect(english(SSHErrorMessage.authenticationRejected)
                == "The server rejected the password or key. Check the server’s credentials (Edit Server) and reconnect.")
        #expect(english(SSHErrorMessage.timedOut).hasPrefix("Timed out: the server didn’t respond."))
    }

    // MARK: - Plurales

    @Test("plural de archivos cambiados (antes hecho a mano)", arguments: [(1, "1 archivo cambiado", "1 file changed"), (5, "5 archivos cambiados", "5 files changed")])
    func changedFilesPlural(count: Int, spanish: String, englishText: String) {
        #expect(ClaudeDoneMessage.body(changedFiles: count) == "Terminó de responder · \(spanish). Revísalos en «Cambios».")
        #expect(english("%lld archivos cambiados", count) == englishText)
        #expect(english("Terminó de responder · %@. Revísalos en «Cambios».", englishText)
                == "Finished responding · \(englishText). Review them in Changes.")
    }

    @Test("resumen del Doctor: plurales en español iguales que antes y en inglés")
    func doctorSummary() {
        let one = DoctorResult(checks: [DoctorCheck(.git, "git", .warning, "x")], finishedAt: Date())
        #expect(one.summary == "1 aviso.")
        let mixed = DoctorResult(checks: [
            DoctorCheck(.git, "git", .warning, "x"),
            DoctorCheck(.tmux, "tmux", .problem, "y"),
            DoctorCheck(.claude, "claude", .problem, "z"),
        ], finishedAt: Date())
        #expect(mixed.summary == "2 problemas y 1 aviso.")
        #expect(english("%lld avisos.", 1) == "1 warning.")
        #expect(english("%lld problemas", 2) == "2 problems")
        #expect(english("%@ y %@.", "2 problems", "1 warning") == "2 problems and 1 warning.")
    }

    @Test("ventanas de una sesión")
    func windowsPlural() {
        #expect(english("%lld ventanas", 1) == "1 window")
        #expect(english("%lld ventanas", 3) == "3 windows")
    }

    // MARK: - Vistas de modelo

    @Test("filtro de estado de proyectos")
    func statusFilterTitles() {
        #expect(ProjectStatusFilter.open.title == "Abiertas")
        #expect(english("Abiertas") == "Open")
        #expect(english("Segundo plano") == "Background")
    }

    @Test("validación de nombres de sesión")
    func sessionNameValidation() {
        #expect(SessionNameValidator.liveValidationMessage(for: "-x") == "El nombre no puede empezar por '-' (tmux lo interpretaría como una opción).")
        #expect(english("El nombre no puede empezar por '-' (tmux lo interpretaría como una opción).")
                == "The name can’t start with “-” (tmux would treat it as an option).")
    }

    @Test("los grupos guardados siguen con su identificador y se muestran traducidos")
    func groupIdentifiers() {
        #expect(SessionGrouping.ungroupedName == "General")
        #expect(VisibleProjectListing.looseGroupName == "Sesiones sueltas")
        #expect(VisibleProjectListing.displayName(ofGroup: VisibleProjectListing.looseGroupName) == "Sesiones sueltas")
        #expect(VisibleProjectListing.displayName(ofGroup: "magic-agents") == "magic-agents")
        #expect(english("Sesiones sueltas") == "Unorganized Sessions")
        #expect(english("General") == "General")
    }

    @Test("tamaños: coma decimal en español, punto en inglés")
    func sizes() {
        #expect(ResourceFormat.gigabytes(0.5) == "0,5 GB")
        #expect(ResourceFormat.percent(0.42) == "42 %")
        #expect(english("%lld %%", 42) == "42%")
    }
}
