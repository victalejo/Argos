//
//  SessionNameValidatorTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("Validación de nombres de sesión")
struct SessionNameValidatorTests {

    @Test("Nombre simple válido se devuelve recortado")
    func validTrimmed() throws {
        #expect(try SessionNameValidator.validate("  main  ") == "main")
    }

    @Test("Se permite '/' para agrupar")
    func allowsSlash() throws {
        #expect(try SessionNameValidator.validate("magic-agents/backend") == "magic-agents/backend")
    }

    @Test("Vacío o solo espacios lanza .empty")
    func empty() {
        #expect(throws: SessionNameValidator.ValidationError.empty) {
            try SessionNameValidator.validate("   ")
        }
    }

    @Test("Caracteres prohibidos de tmux lanzan .forbiddenCharacter", arguments: [":", "."])
    func forbidden(char: String) {
        #expect(throws: SessionNameValidator.ValidationError.forbiddenCharacter(Character(char))) {
            try SessionNameValidator.validate("a\(char)b")
        }
    }

    @Test("Caracteres de control embebidos lanzan .controlCharacter", arguments: ["a\nb", "a\tb", "a\u{0007}b"])
    func control(input: String) {
        #expect(throws: SessionNameValidator.ValidationError.controlCharacter) {
            try SessionNameValidator.validate(input)
        }
    }

    @Test("Prefijo '-' lanza .leadingDash (inyección de opciones a tmux)")
    func leadingDash() {
        #expect(throws: SessionNameValidator.ValidationError.leadingDash) {
            try SessionNameValidator.validate("-X")
        }
    }

    @Test("isValid refleja validez sin lanzar")
    func isValid() {
        #expect(SessionNameValidator.isValid("ok"))
        #expect(!SessionNameValidator.isValid(""))
        #expect(!SessionNameValidator.isValid("a:b"))
        #expect(!SessionNameValidator.isValid("-x"))
    }

    @Test("liveValidationMessage no reporta el caso vacío pero sí los inválidos")
    func liveMessage() {
        #expect(SessionNameValidator.liveValidationMessage(for: "") == nil)
        #expect(SessionNameValidator.liveValidationMessage(for: "ok") == nil)
        #expect(SessionNameValidator.liveValidationMessage(for: "a.b") != nil)
    }
}
