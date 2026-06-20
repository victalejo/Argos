//
//  TOFUHostKeyValidatorTests.swift
//  ArgosTests
//
//  Verifica la gestión del almacén de huellas TOFU (`known_hosts.json`) a través de
//  `forget`, la acción que la UI usa para re-confiar tras una reinstalación legítima.
//  El contrato es delicado para seguridad: olvidar la huella equivocada (o no olvidar
//  la correcta) rompe la protección MitM.
//

import Foundation
import Testing
@testable import Argos

@Suite("TOFUHostKeyValidator (known_hosts)")
struct TOFUHostKeyValidatorTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-knownhosts-\(UUID().uuidString).json")
    }

    private func seed(_ entries: [String: String], at url: URL) throws {
        try JSONEncoder().encode(entries).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    @Test("forget elimina solo el endpoint indicado y conserva el resto")
    func forgetRemovesOnlyTarget() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed([
            "alpha:22": "SHA256:aaa",
            "beta:2222": "SHA256:bbb",
        ], at: url)

        TOFUHostKeyValidator.forget(host: "alpha", port: 22, storeURL: url)

        let remaining = try read(url)
        #expect(remaining["alpha:22"] == nil)
        #expect(remaining["beta:2222"] == "SHA256:bbb")
    }

    @Test("forget de un endpoint ausente no altera el archivo")
    func forgetAbsentIsNoOp() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed(["beta:2222": "SHA256:bbb"], at: url)

        TOFUHostKeyValidator.forget(host: "no-existe", port: 22, storeURL: url)

        let remaining = try read(url)
        #expect(remaining == ["beta:2222": "SHA256:bbb"])
    }

    @Test("forget distingue por puerto (mismo host, puerto distinto)")
    func forgetIsPortSensitive() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed([
            "host:22": "SHA256:p22",
            "host:2222": "SHA256:p2222",
        ], at: url)

        TOFUHostKeyValidator.forget(host: "host", port: 2222, storeURL: url)

        let remaining = try read(url)
        #expect(remaining["host:22"] == "SHA256:p22")
        #expect(remaining["host:2222"] == nil)
    }

    @Test("forget sobre un known_hosts inexistente no crea el archivo ni revienta")
    func forgetMissingFileIsSafe() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        TOFUHostKeyValidator.forget(host: "alpha", port: 22, storeURL: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
