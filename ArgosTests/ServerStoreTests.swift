//
//  ServerStoreTests.swift
//  ArgosTests
//

import Foundation
import Testing
@testable import Argos

@Suite("Modelo Server")
struct ServerModelTests {

    @Test("Server hace round-trip por Codable")
    func codableRoundTrip() throws {
        let server = Server(
            name: "dev", host: "10.0.0.1", port: 2222,
            username: "victalejo", privateKeyPath: "~/.ssh/id_ed25519",
            requiresPassphrase: true
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded == server)
    }

    @Test("endpoint compone host:port")
    func endpoint() {
        let server = Server(name: "x", host: "h", port: 22, username: "u", privateKeyPath: "/k")
        #expect(server.endpoint == "h:22")
    }
}

@MainActor
@Suite("ServerStore (persistencia)")
struct ServerStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-test-\(UUID().uuidString).json")
    }

    @Test("Primer arranque arranca con la lista vacía (sin seed hardcodeado)")
    func emptyOnFirstRun() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ServerStore(storeURL: url)
        #expect(store.servers.isEmpty)
    }

    @Test("add / update / remove persisten y se recargan")
    func crudPersists() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ServerStore(storeURL: url)
        let nuevo = Server(name: "prod", host: "p", port: 22, username: "u", privateKeyPath: "/k")
        store.add(nuevo)
        #expect(store.servers.count == 1)

        var editado = nuevo
        editado.name = "producción"
        store.update(editado)

        // Recarga desde el MISMO archivo: la persistencia debe reflejar los cambios.
        let recargado = ServerStore(storeURL: url)
        #expect(recargado.servers.count == 1)
        #expect(recargado.server(withID: nuevo.id)?.name == "producción")

        recargado.remove(editado)
        let recargado2 = ServerStore(storeURL: url)
        #expect(recargado2.server(withID: nuevo.id) == nil)
        #expect(recargado2.servers.isEmpty)
    }

    @Test("servers.json corrupto se respalda en vez de sobrescribirse")
    func corruptFileIsBackedUp() throws {
        let url = tempURL()
        let dir = url.deletingLastPathComponent()
        let backupPrefix = url.lastPathComponent + ".corrupt-"
        defer {
            try? FileManager.default.removeItem(at: url)
            // Limpia los backups generados por esta prueba.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasPrefix(backupPrefix) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }

        // Archivo presente pero NO decodificable.
        try Data("{ esto no es json válido".utf8).write(to: url)

        let store = ServerStore(storeURL: url)
        #expect(store.servers.isEmpty)
        // El corrupto se movió a un backup (ya no está en su ruta original).
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasPrefix(backupPrefix) } ?? []
        #expect(!backups.isEmpty)
    }
}
