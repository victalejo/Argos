//
//  GoldenParityTests.swift
//  ArgosTests
//
//  Los goldens de `android/core/src/test/resources/swift-golden/` son la red contra la
//  deriva Swift → Kotlin: Android comprueba BYTE A BYTE que genera lo mismo. Este test los
//  genera con el código Swift REAL (`GoldenCatalog`) y los compara con los del repo, así
//  que cambiar un script en Swift sin regenerarlos falla aquí, y el test de Android falla
//  hasta que Kotlin se ajuste.
//
//  Regenerar: `scripts/regenerate-swift-goldens.sh` (pasa `ARGOS_REGENERATE_GOLDENS=1` al
//  proceso de tests y reescribe los archivos).
//

import Foundation
import Testing
@testable import Argos

@Suite("Goldens de paridad con Android")
struct GoldenParityTests {

    /// Carpeta de los goldens, relativa a ESTE archivo (vale igual en el runner de la CI).
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("android/core/src/test/resources/swift-golden", isDirectory: true)

    static let regenerateVariable = "ARGOS_REGENERATE_GOLDENS"
    static let howToRegenerate = "Regenera con scripts/regenerate-swift-goldens.sh y ajusta Kotlin hasta que "
        + "./gradlew :core:test pase."

    static var isRegenerating: Bool {
        ProcessInfo.processInfo.environment[regenerateVariable] == "1"
    }

    /// Goldens del repo SIN generador porque su texto vive dentro de un método de
    /// `SSHService` (no hay función pura que llamar sin conexión). Añadir uno nuevo sin
    /// generador ni entrada aquí hace fallar `todoGoldenTieneGenerador`.
    static let withoutGenerator: Set<String> = [
        "locate-claude",        // SSHService.locateClaude()
        "kill-agent",           // SSHService.killAgentProcess(pid:)
        "mem-available",        // SSHService.availableMemoryKB()
        "list-dirs",            // SSHService.listRemoteDirectories(at:)
        "dir-exists",           // SSHService.remoteDirectoryExists(_:)
        "auth-status",          // SSHService.claudeAuthStatus()
        "clipboard-forwarding", // SSHService.enableClipboardForwarding()
    ]

    private static func goldenNamesOnDisk() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Set(files.filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) })
    }

    @Test func laCarpetaDeGoldensExiste() {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: Self.directory.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "No se encuentra \(Self.directory.path)")
    }

    @Test func cadaGoldenCoincideConElSwiftReal() throws {
        let generated = try GoldenCatalog.all()
        if Self.isRegenerating {
            for (name, content) in generated {
                try Data(content.utf8).write(to: Self.directory.appendingPathComponent("\(name).txt"))
            }
            return
        }
        var differing: [String] = []
        for (name, content) in generated.sorted(by: { $0.key < $1.key }) {
            let url = Self.directory.appendingPathComponent("\(name).txt")
            guard let data = FileManager.default.contents(atPath: url.path) else {
                differing.append("\(name) (falta el archivo)")
                continue
            }
            if data != Data(content.utf8) { differing.append(name) }
        }
        #expect(differing.isEmpty, "Goldens que difieren del Swift real: \(differing.joined(separator: ", ")). \(Self.howToRegenerate)")
    }

    @Test func todoGoldenTieneGeneradorOEstaEnLaListaDeExcepciones() throws {
        let generated = Set(try GoldenCatalog.all().keys)
        let onDisk = try Self.goldenNamesOnDisk()
        let orphans = onDisk.subtracting(generated).subtracting(Self.withoutGenerator).sorted()
        let hint = "Añádelos a GoldenCatalog o, si su texto no sale de una función pura, a GoldenParityTests.withoutGenerator."
        #expect(orphans.isEmpty, "Goldens sin generador: \(orphans). \(hint)")
        let stale = Self.withoutGenerator.subtracting(onDisk).sorted()
        #expect(stale.isEmpty, "Excepciones que ya no existen en disco: \(stale)")
        let both = Self.withoutGenerator.intersection(generated).sorted()
        #expect(both.isEmpty, "Con generador y en la lista de excepciones a la vez: \(both)")
    }
}
