//
//  MacSyncStoreTests.swift
//  ArgosTests
//
//  Lectura del manifiesto de "Enviar al Mac": "no hay copia" (nil) NO debe confundirse
//  con "el registro existe pero no se puede leer" (error con la causa).
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Enviar al Mac: manifiesto local")
struct MacSyncStoreTests {

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSyncStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ data: Data, for id: UUID) throws {
        try data.write(to: directory.appendingPathComponent("\(id.uuidString).json"))
    }

    @Test("Sin archivo: nil (este Mac no tiene la copia)")
    func missingManifestIsNil() throws {
        #expect(try MacSyncStore.loadManifest(for: UUID(), in: directory) == nil)
    }

    @Test("Manifiesto válido: se decodifica")
    func validManifestLoads() throws {
        let id = UUID()
        let manifest = SyncManifest(
            projectID: id,
            serverID: UUID(),
            remoteRoot: "/srv/app",
            localPath: "/Users/x/Desarrollo/app",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            files: ["a.txt": SyncFile(path: "a.txt", size: 1, mtime: 2, mode: 0o644, linkTarget: nil)]
        )
        try write(JSONEncoder.projects.encode(manifest), for: id)
        #expect(try MacSyncStore.loadManifest(for: id, in: directory) == manifest)
    }

    @Test("Manifiesto corrupto: lanza error en vez de fingir que no hay copia")
    func corruptManifestThrows() throws {
        let id = UUID()
        try write(Data("{ no es json".utf8), for: id)
        #expect(throws: MacSyncStore.ManifestError.self) {
            try MacSyncStore.loadManifest(for: id, in: directory)
        }
    }
}
