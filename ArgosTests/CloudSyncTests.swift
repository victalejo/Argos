//
//  CloudSyncTests.swift
//  ArgosTests
//
//  Sincronización por iCloud: qué viaja (sin bookmarks), fusión (última edición gana,
//  lápidas, huellas que nunca se reemplazan) y el coordinador entre dos «dispositivos»
//  que comparten un iCloud en memoria.
//

import Foundation
import Testing
@testable import Argos

private func server(_ name: String, id: UUID = UUID(), host: String = "srv.example", bookmark: Data? = nil) -> Server {
    Server(id: id, name: name, host: host, username: "ana", authMethod: .key,
           privateKeyPath: "~/.ssh/id_ed25519", privateKeyBookmark: bookmark)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("iCloud: documento y fusión")
struct ServerSyncDocumentTests {

    @Test func losBookmarksNoViajan() {
        let local = ServerSync.localDocument(
            servers: [server("a", bookmark: Data([1, 2, 3]))], knownHosts: [:], previous: .empty, now: t0
        )
        #expect(local.servers.values.first?.server.privateKeyBookmark == nil)
    }

    @Test func soloSeFechaLoQueCambia() {
        let id = UUID()
        let first = ServerSync.localDocument(servers: [server("a", id: id)], knownHosts: [:], previous: .empty, now: t0)
        let same = ServerSync.localDocument(servers: [server("a", id: id)], knownHosts: [:], previous: first, now: t0 + 60)
        #expect(same.servers[id.uuidString]?.modifiedAt == t0)
        let edited = ServerSync.localDocument(servers: [server("b", id: id)], knownHosts: [:], previous: first, now: t0 + 60)
        #expect(edited.servers[id.uuidString]?.modifiedAt == t0 + 60)
        let removed = ServerSync.localDocument(servers: [], knownHosts: [:], previous: first, now: t0 + 90)
        #expect(removed.servers.isEmpty && removed.deleted[id.uuidString] == t0 + 90)
    }

    @Test func ganaLaEdicionMasReciente() {
        let id = UUID()
        var local = ServerSyncDocument(), remote = ServerSyncDocument()
        local.servers[id.uuidString] = SyncedServer(server: server("viejo", id: id), modifiedAt: t0)
        remote.servers[id.uuidString] = SyncedServer(server: server("nuevo", id: id), modifiedAt: t0 + 10)
        #expect(ServerSync.merge(local: local, remote: remote, now: t0 + 20).servers[id.uuidString]?.server.name == "nuevo")
        #expect(ServerSync.merge(local: remote, remote: local, now: t0 + 20).servers[id.uuidString]?.server.name == "nuevo")
    }

    @Test func unBorradoPosteriorGanaYUnaEdicionPosteriorResucita() {
        let id = UUID()
        var edited = ServerSyncDocument()
        edited.servers[id.uuidString] = SyncedServer(server: server("a", id: id), modifiedAt: t0)
        var deleted = ServerSyncDocument()
        deleted.deleted[id.uuidString] = t0 + 5
        #expect(ServerSync.merge(local: edited, remote: deleted, now: t0 + 6).servers.isEmpty)

        edited.servers[id.uuidString]?.modifiedAt = t0 + 9
        let merged = ServerSync.merge(local: edited, remote: deleted, now: t0 + 10)
        #expect(merged.servers[id.uuidString] != nil)
        #expect(merged.deleted[id.uuidString] == nil)
    }

    @Test func lasLapidasViejasCaducan() {
        var remote = ServerSyncDocument()
        remote.deleted["x"] = t0
        let merged = ServerSync.merge(local: .empty, remote: remote, now: t0 + ServerSyncDocument.tombstoneLifetime + 1)
        #expect(merged.deleted.isEmpty)
    }

    @Test func unaHuellaRemotaDistintaNuncaReemplazaLaLocal() {
        var local = ServerSyncDocument(), remote = ServerSyncDocument()
        local.knownHosts["srv:22"] = TrustedHost(fingerprint: "SHA256:local", trustedAt: t0)
        remote.knownHosts["srv:22"] = TrustedHost(fingerprint: "SHA256:otra", trustedAt: t0 + 100)
        remote.knownHosts["nuevo:22"] = TrustedHost(fingerprint: "SHA256:n", trustedAt: t0)
        let merged = ServerSync.merge(local: local, remote: remote, now: t0 + 200)
        #expect(merged.knownHosts["srv:22"]?.fingerprint == "SHA256:local")
        let changes = ServerSync.hostChanges(in: merged, local: ["srv:22": "SHA256:local"])
        #expect(changes.add == ["nuevo:22": "SHA256:n"])
        #expect(changes.forget.isEmpty)
    }

    @Test func olvidarUnaHuellaSePropaga() {
        // Dispositivo A olvidó la huella (servidor reinstalado) después de confiarla.
        var a = ServerSyncDocument(), b = ServerSyncDocument()
        a.forgottenHosts["srv:22"] = ForgottenHost(fingerprint: "SHA256:vieja", forgottenAt: t0 + 50)
        b.knownHosts["srv:22"] = TrustedHost(fingerprint: "SHA256:vieja", trustedAt: t0)
        let merged = ServerSync.merge(local: b, remote: a, now: t0 + 60)
        #expect(merged.knownHosts["srv:22"] == nil)
        #expect(ServerSync.hostChanges(in: merged, local: ["srv:22": "SHA256:vieja"]).forget == ["srv:22"])
    }

    @Test func unaLapidaDeOtraHuellaNoBorraLaLocal() {
        // iCloud manipulado: «olvida» una huella que NO es la fijada aquí.
        var local = ServerSyncDocument(), remote = ServerSyncDocument()
        local.knownHosts["srv:22"] = TrustedHost(fingerprint: "SHA256:fijada", trustedAt: t0)
        remote.forgottenHosts["srv:22"] = ForgottenHost(fingerprint: "SHA256:otra", forgottenAt: t0 + 50)
        let merged = ServerSync.merge(local: local, remote: remote, now: t0 + 60)
        #expect(merged.knownHosts["srv:22"]?.fingerprint == "SHA256:fijada")
        #expect(ServerSync.hostChanges(in: merged, local: ["srv:22": "SHA256:fijada"]).forget.isEmpty)
    }

    @Test func lasFechasDelFuturoNoGananSiempre() {
        let id = UUID()
        var local = ServerSyncDocument(), remote = ServerSyncDocument()
        local.servers[id.uuidString] = SyncedServer(server: server("local", id: id), modifiedAt: t0)
        remote.servers[id.uuidString] = SyncedServer(server: server("del-futuro", id: id), modifiedAt: t0 + 999_999)
        // Recortada a «ahora» (= t0), empata con la local y gana la local.
        #expect(ServerSync.merge(local: local, remote: remote, now: t0).servers[id.uuidString]?.server.name == "local")
    }

    @Test func cambiarElDestinoDesdeOtroDispositivoInvalidaLosSecretos() {
        let a = server("a"), b = server("b")
        var aMovido = a; aMovido.host = "atacante.example"
        var bRenombrado = b; bRenombrado.name = "b2"
        #expect(ServerSync.credentialsToInvalidate(before: [a, b], after: [aMovido, bRenombrado]) == [a.id])
    }

    @Test func aplicarConservaOrdenYBookmarksLocales() {
        let a = server("a", bookmark: Data([9])), b = server("b")
        var doc = ServerSyncDocument()
        doc.servers[a.id.uuidString] = SyncedServer(server: ServerSync.portable(a), modifiedAt: t0)
        doc.servers[b.id.uuidString] = SyncedServer(server: ServerSync.portable(b), modifiedAt: t0)
        let nuevo = server("0-nuevo")
        doc.servers[nuevo.id.uuidString] = SyncedServer(server: nuevo, modifiedAt: t0)
        let result = ServerSync.applying(doc, to: [b, a])
        #expect(result.map(\.name) == ["b", "a", "0-nuevo"])
        #expect(result[1].privateKeyBookmark == Data([9]))
    }

    @Test func siOtroDispositivoCambiaLaRutaDeLaClaveSeDescartaElBookmark() {
        let local = server("a", bookmark: Data([9]))
        var remoto = ServerSync.portable(local)
        remoto.privateKeyPath = "~/.ssh/otra"
        var doc = ServerSyncDocument()
        doc.servers[local.id.uuidString] = SyncedServer(server: remoto, modifiedAt: t0)
        #expect(ServerSync.applying(doc, to: [local]).first?.privateKeyBookmark == nil)
    }
}

/// iCloud en memoria compartido por varios «dispositivos».
private final class MemoryCloud: CloudKeyValueStore {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func setData(_ data: Data?, forKey key: String) { values[key] = data }
    func synchronize() -> Bool { true }
}

@MainActor
@Suite("iCloud: coordinador entre dispositivos")
struct CloudServerSyncTests {

    private struct Device {
        let store: ServerStore
        let sync: CloudServerSync
        let knownHosts: URL
    }

    private func device(_ cloud: MemoryCloud, _ folder: URL, _ name: String) -> Device {
        let dir = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ServerStore(storeURL: dir.appendingPathComponent("servers.json"))
        let defaults = UserDefaults(suiteName: "argos.tests.cloud.\(UUID())")!
        let hosts = dir.appendingPathComponent("known_hosts.json")
        let sync = CloudServerSync(store: store, cloud: cloud, defaults: defaults,
                                   stateURL: dir.appendingPathComponent("icloud-sync.json"), knownHostsURL: hosts)
        return Device(store: store, sync: sync, knownHosts: hosts)
    }

    @Test func unServidorCreadoEnElMacApareceEnElIPhoneYSeBorraEnAmbos() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argos-cloud-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let mac = device(cloud, folder, "mac"), iphone = device(cloud, folder, "iphone")

        let prod = server("producción")
        mac.store.add(prod)
        mac.sync.sync(now: t0)
        iphone.sync.sync(now: t0 + 1)
        #expect(iphone.store.servers.map(\.name) == ["producción"])

        // Borrado en el iPhone → desaparece del Mac, avisando para limpiar lo suyo.
        var removedOnMac: [UUID] = []
        mac.sync.onRemoteRemoval = { removedOnMac.append($0.id) }
        iphone.store.remove(iphone.store.servers[0])
        iphone.sync.sync(now: t0 + 2)
        mac.sync.sync(now: t0 + 3)
        #expect(mac.store.servers.isEmpty)
        #expect(removedOnMac == [prod.id])
    }

    @Test func lasHuellasViajanPeroNoSePisan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argos-cloud-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let mac = device(cloud, folder, "mac"), iphone = device(cloud, folder, "iphone")

        TOFUHostKeyValidator.trust(["srv:22": "SHA256:buena"], storeURL: mac.knownHosts)
        TOFUHostKeyValidator.trust(["srv:22": "SHA256:del-iphone"], storeURL: iphone.knownHosts)
        mac.sync.sync(now: t0)
        iphone.sync.sync(now: t0 + 1)
        #expect(TOFUHostKeyValidator.allTrusted(storeURL: iphone.knownHosts)["srv:22"] == "SHA256:del-iphone")

        TOFUHostKeyValidator.trust(["otro:2222": "SHA256:o"], storeURL: mac.knownHosts)
        mac.sync.sync(now: t0 + 2)
        iphone.sync.sync(now: t0 + 3)
        #expect(TOFUHostKeyValidator.allTrusted(storeURL: iphone.knownHosts)["otro:2222"] == "SHA256:o")
    }

    @Test func unDocumentoIlegibleODeOtraVersionNoSeSobrescribe() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argos-cloud-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let mac = device(cloud, folder, "mac")
        mac.store.add(server("a"))

        cloud.values[CloudServerSync.documentKey] = Data("{no es json".utf8)
        mac.sync.sync(now: t0)
        #expect(cloud.values[CloudServerSync.documentKey] == Data("{no es json".utf8))

        var futuro = ServerSyncDocument()
        futuro.version = ServerSyncDocument.supportedVersion + 1
        let futuroData = try ServerSync.encode(futuro)
        cloud.values[CloudServerSync.documentKey] = futuroData
        mac.sync.sync(now: t0)
        #expect(cloud.values[CloudServerSync.documentKey] == futuroData)
        #expect(mac.store.servers.map(\.name) == ["a"])
    }

    @Test func desactivadaNoTocaICloud() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argos-cloud-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let mac = device(cloud, folder, "mac")
        mac.sync.isEnabled = false
        mac.store.add(server("a"))
        mac.sync.sync(now: t0)
        #expect(cloud.values.isEmpty)
    }
}
