//
//  SpreadsheetPreviewTests.swift
//  ArgosTests
//
//  Hojas de cálculo en el explorador: se reconocen por nombre y por firma, y el archivo
//  temporal para Vista Rápida no puede salir de su carpeta.
//

import Foundation
import Testing
@testable import Argos

@Suite("Visor de hojas de cálculo")
struct SpreadsheetPreviewTests {

    private let zipHeader = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00])
    private let oleHeader = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

    @Test("Excel y Numbers se reconocen por extensión y leen hasta su límite", arguments: [
        "datos.xlsx", "Informe.XLSX", "macros.xlsm", "viejo.xls", "plan.numbers",
    ])
    func kindByName(name: String) {
        #expect(FilePreview.kind(forName: name) == .spreadsheet)
        #expect(FilePreview.readLimit(for: .spreadsheet) == FilePreview.maxSpreadsheetBytes)
    }

    @Test("Con bytes: ZIP u OLE2 = hoja de cálculo; otra cosa = binario")
    func kindByContent() {
        #expect(FilePreview.kind(forName: "a.xlsx", data: zipHeader) == .spreadsheet)
        #expect(FilePreview.kind(forName: "a.xls", data: oleHeader) == .spreadsheet)
        #expect(FilePreview.kind(forName: "a.xlsx", data: Data("no soy excel".utf8)) == .binary)
        #expect(FilePreview.kind(forName: "a.xlsx", data: Data()) == .binary)
    }

    @Test("El CSV sigue viéndose como texto")
    func csvStaysText() {
        #expect(FilePreview.kind(forName: "datos.csv", data: Data("a,b\n1,2\n".utf8)) == .code(language: nil))
    }

    @Test("El nombre del servidor no puede escapar de la carpeta temporal", arguments: [
        ("../../etc/passwd.xlsx", "passwd.xlsx"),
        ("/tmp/x/datos.xlsx", "datos.xlsx"),
        ("..", "archivo"),
        ("", "archivo"),
        ("a\u{0}b\u{7}.xlsx", "ab.xlsx"),
        ("..oculto.xlsx", "oculto.xlsx"),
    ])
    func safeName(input: String, expected: String) {
        #expect(QuickLookTempFile.safeName(input) == expected)
    }

    @Test("Escribe el archivo con su contenido y lo borra al cerrar")
    func writesAndRemoves() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-ql-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try QuickLookTempFile(data: zipHeader, name: "../datos.xlsx", base: base)
        #expect(file.url.lastPathComponent == "datos.xlsx")
        #expect(file.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == base.standardizedFileURL)
        #expect(try Data(contentsOf: file.url) == zipHeader)
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}
