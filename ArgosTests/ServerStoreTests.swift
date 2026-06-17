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

    @Test("Primer arranque siembra el servidor de desarrollo")
    func seedsOnFirstRun() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ServerStore(storeURL: url)
        #expect(store.servers.count == 1)
        #expect(store.servers.first?.name == "dev")
    }

    @Test("add / update / remove persisten y se recargan")
    func crudPersists() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ServerStore(storeURL: url)
        let nuevo = Server(name: "prod", host: "p", port: 22, username: "u", privateKeyPath: "/k")
        store.add(nuevo)
        #expect(store.servers.count == 2)

        var editado = nuevo
        editado.name = "producción"
        store.update(editado)

        // Recarga desde el MISMO archivo: la persistencia debe reflejar los cambios.
        let recargado = ServerStore(storeURL: url)
        #expect(recargado.servers.count == 2)
        #expect(recargado.server(withID: nuevo.id)?.name == "producción")

        recargado.remove(editado)
        let recargado2 = ServerStore(storeURL: url)
        #expect(recargado2.server(withID: nuevo.id) == nil)
        #expect(recargado2.servers.count == 1)
    }
}
