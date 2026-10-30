//
//  ProjectSyncEngineTests.swift
//  ArgosTests
//
//  Ida y vuelta completa con el mock y carpetas temporales reales: enviar al Mac,
//  editar/crear/borrar en el Mac y enviar al servidor. Incluye un listado malicioso
//  (enlace + archivo "a través" del enlace) que no debe escribir fuera de la carpeta.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Enviar al Mac: motor")
struct ProjectSyncEngineTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argos-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func serverFile(_ path: String, _ content: String, mtime: Int = 1_000) -> (SyncFile, Data) {
        let data = Data(content.utf8)
        return (SyncFile(path: path, size: UInt64(data.count), mtime: mtime, mode: 0o644, linkTarget: nil), data)
    }

    @Test("Ida y vuelta: solo viaja lo cambiado en el Mac")
    func roundTrip() async throws {
        let mock = MockSSHService()
        for (file, data) in [serverFile("README.md", "hola"), serverFile("src/app.ts", "v1"), serverFile("viejo.txt", "x")] {
            mock.syncServerFiles.append(file)
            mock.syncServerData[file.path] = data
        }
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let localRoot = parent.appendingPathComponent("proyecto")
        let engine = ProjectSyncEngine()

        // Servidor → Mac
        let state = try await engine.download(files: mock.syncServerFiles, from: "/srv/p", to: localRoot, service: mock)
        #expect(try String(contentsOf: localRoot.appendingPathComponent("src/app.ts"), encoding: .utf8) == "v1")
        #expect(engine.doneFiles == 3)

        // Sin tocar nada: plan vacío (las fechas se igualaron al descargar).
        let manifest = SyncManifest(projectID: UUID(), serverID: UUID(), remoteRoot: "/srv/p",
                                    localPath: localRoot.path, createdAt: Date(), files: state)
        let (unchanged, _) = try await engine.plan(manifest: manifest, localRoot: localRoot, service: mock)
        #expect(unchanged.isEmpty)

        // Editar, crear y borrar en el Mac.
        try Data("v2 editado".utf8).write(to: localRoot.appendingPathComponent("src/app.ts"))
        try FileManager.default.createDirectory(at: localRoot.appendingPathComponent("nuevo"), withIntermediateDirectories: true)
        try Data("nuevo".utf8).write(to: localRoot.appendingPathComponent("nuevo/archivo.ts"))
        try FileManager.default.removeItem(at: localRoot.appendingPathComponent("viejo.txt"))

        let (plan, _) = try await engine.plan(manifest: manifest, localRoot: localRoot, service: mock)
        #expect(Set(plan.uploads.map(\.path)) == ["src/app.ts", "nuevo/archivo.ts"])
        #expect(plan.deletions == ["viejo.txt"])
        #expect(plan.conflicts.isEmpty)

        // Mac → servidor
        try await engine.upload(plan: plan, remoteRoot: "/srv/p", localRoot: localRoot, service: mock)
        #expect(Set(mock.uploadedSyncPaths) == ["src/app.ts", "nuevo/archivo.ts"])
        #expect(mock.deletedSyncPaths == ["viejo.txt"])
        #expect(String(decoding: mock.syncServerData["src/app.ts"] ?? Data(), as: UTF8.self) == "v2 editado")
    }

    @Test("Un listado malicioso no escribe fuera de la carpeta del proyecto")
    func maliciousListing() async throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("fuera")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let mock = MockSSHService()
        let link = SyncFile(path: "a", size: 1, mtime: 1, mode: 0o777, linkTarget: outside.path)
        let (through, data) = serverFile("a/pwned.txt", "malo")
        let (escape, escapeData) = serverFile("b", "x")
        let escapingLink = SyncFile(path: "c", size: 1, mtime: 1, mode: 0o777, linkTarget: "../fuera")
        mock.syncServerFiles = [link, through, escape, escapingLink]
        mock.syncServerData = [through.path: data, escape.path: escapeData]

        let localRoot = parent.appendingPathComponent("proyecto")
        _ = try await ProjectSyncEngine().download(files: mock.syncServerFiles, from: "/srv", to: localRoot, service: mock)

        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned.txt").path))
        #expect(FileManager.default.fileExists(atPath: localRoot.appendingPathComponent("b").path))
        // Ni el enlace absoluto ni el que escapa con ".." se crean.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: localRoot.appendingPathComponent("a").path)) == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: localRoot.appendingPathComponent("c").path)) == nil)
    }

    @Test("No sobrescribe una carpeta destino con contenido")
    func refusesNonEmptyDestination() async throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let localRoot = parent.appendingPathComponent("proyecto")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try Data("mío".utf8).write(to: localRoot.appendingPathComponent("importante.txt"))

        await #expect(throws: (any Error).self) {
            _ = try await ProjectSyncEngine().download(files: [], from: "/srv", to: localRoot, service: MockSSHService())
        }
        #expect(FileManager.default.fileExists(atPath: localRoot.appendingPathComponent("importante.txt").path))
    }
}
