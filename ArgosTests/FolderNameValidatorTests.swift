//
//  FolderNameValidatorTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("Nombre de carpeta nueva")
struct FolderNameValidatorTests {
    @Test("Nombres válidos (se recortan espacios)", arguments: [
        ("proyecto", "proyecto"), ("  mi app  ", "mi app"), ("-raro", "-raro"), (".config", ".config"), ("ñandú 2", "ñandú 2"),
    ])
    func valid(raw: String, expected: String) {
        #expect(FolderNameValidator.validate(raw) == .success(expected))
    }

    @Test("Nombres inválidos", arguments: [
        ("", FolderNameValidator.Failure.empty),
        ("   ", .empty),
        (".", .reserved),
        ("..", .reserved),
        ("a/b", .containsSlash),
        ("../fuera", .containsSlash),
        ("tab\tname", .controlCharacter),
        (String(repeating: "x", count: 256), .tooLong),
    ])
    func invalid(raw: String, failure: FolderNameValidator.Failure) {
        #expect(FolderNameValidator.validate(raw) == .failure(failure))
    }
}
