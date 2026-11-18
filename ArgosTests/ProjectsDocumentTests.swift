//
//  ProjectsDocumentTests.swift
//  ArgosTests
//
//  projects.json compartido por Mac, iPhone/iPad y Android: compatibilidad de bytes,
//  claves desconocidas, proyectos dañados, versión futura, conflictos de escritura y el
//  script de escritura con cerrojo y huella.
//

import Testing
import Foundation
@testable import Argos

@Suite("projects.json: documento")
struct ProjectsDocumentTests {

    private static let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let date = Date(timeIntervalSince1970: 1_762_509_600)

    private static func project(_ id: UUID, _ name: String, checkout: MacCheckout? = nil) -> Project {
        Project(id: id, name: name, group: "ia", path: "/srv/\(name)", startupCommand: nil, createdAt: date, macCheckout: checkout)
    }

    @Test("Con solo claves conocidas, los bytes son los del formato de siempre")
    func sameBytesAsLegacy() throws {
        let projects = [Self.project(Self.id1, "uno"), Self.project(Self.id2, "dos", checkout: MacCheckout(macName: "M", macID: "x", date: Self.date))]
        let legacy = try ProjectsFile(projects: projects).encoded()
        let document = try ProjectsDocument.empty.replacingProjects(projects)
        #expect(try document.encoded() == legacy)
        #expect(try ProjectsDocument.empty.encoded() == ProjectsFile.empty.encoded())
        // Y lo que escribe el documento lo sigue leyendo el decodificador antiguo.
        #expect(try ProjectsFile.decode(String(decoding: try document.encoded(), as: UTF8.self)).projects == projects)
    }

    @Test("Vacío = sin proyectos; JSON roto o sin version/projects = archivo dañado")
    func invalidFiles() throws {
        #expect(try ProjectsDocument.parse("  \n") == .empty)
        for text in ["{ roto", "[]", "{\"projects\": []}", "{\"version\": 1}", "{\"version\": \"1\", \"projects\": []}"] {
            #expect(throws: ProjectError.invalidFile) { try ProjectsDocument.parse(text) }
        }
    }

    @Test("Las claves desconocidas del archivo, de cada proyecto y de macCheckout sobreviven a una reescritura")
    func unknownKeysSurvive() throws {
        let text = """
        {
          "futuro" : { "a" : [1, 2.5, true, null] },
          "projects" : [
            {
              "color" : "verde",
              "createdAt" : "2025-11-07T10:00:00Z",
              "group" : "ia",
              "id" : "11111111-1111-1111-1111-111111111111",
              "macCheckout" : { "date" : "2025-11-07T10:00:00Z", "macID" : "x", "macName" : "M", "rama" : "main" },
              "name" : "uno",
              "path" : "/srv/uno"
            }
          ],
          "version" : 1
        }
        """
        let document = try ProjectsDocument.parse(text)
        var projects = document.projects
        #expect(projects.count == 1)
        projects[0].name = "uno-renombrado"
        projects[0].group = nil
        let rewritten = try ProjectsDocument.parse(String(decoding: try document.replacingProjects(projects).encoded(), as: UTF8.self))
        #expect(rewritten.extra["futuro"] == .object(["a": .array([.int(1), .double(2.5), .bool(true), .null])]))
        guard case .valid(let project, let raw) = rewritten.entries.first else { Issue.record("Sin proyecto"); return }
        #expect(project.name == "uno-renombrado")
        #expect(raw["color"] == .string("verde"))
        #expect(raw["group"] == nil)
        #expect(raw["macCheckout"]?["rama"] == .string("main"))

        // Quitar el checkout lo quita entero (también sus claves desconocidas).
        projects[0].macCheckout = nil
        let cleared = try document.replacingProjects(projects)
        guard case .valid(_, let clearedRaw) = cleared.entries.first else { Issue.record("Sin proyecto"); return }
        #expect(clearedRaw["macCheckout"] == nil)
        #expect(clearedRaw["color"] == .string("verde"))
    }

    @Test("Un proyecto dañado entre varios buenos se aparta, se avisa y se conserva al reescribir")
    func damagedProjectIsKept() throws {
        let text = """
        {"version": 1, "projects": [
          {"id": "11111111-1111-1111-1111-111111111111", "name": "uno", "path": "/a", "createdAt": "2025-11-07T10:00:00Z"},
          {"id": "33333333-3333-3333-3333-333333333333", "name": "sin fecha", "path": "/b"},
          {"id": "22222222-2222-2222-2222-222222222222", "name": "dos", "path": "/c", "createdAt": "ayer"},
          {"id": "44444444-4444-4444-4444-444444444444", "name": "tres", "path": "/d", "createdAt": "2025-11-07T10:00:00Z"}
        ]}
        """
        let document = try ProjectsDocument.parse(text)
        #expect(document.projects.map(\.name) == ["uno", "tres"])
        #expect(document.invalidCount == 2)
        let report = ProjectsLoadReport(document: document)
        #expect(report.warning?.contains("2 proyectos") == true)

        let updated = try document.replacingProjects(document.projects.filter { $0.name != "tres" })
        let reread = try ProjectsDocument.parse(String(decoding: try updated.encoded(), as: UTF8.self))
        #expect(reread.projects.map(\.name) == ["uno"])
        #expect(reread.invalidCount == 2)
        let names = reread.entries.compactMap { entry -> String? in
            if case .invalid(let value) = entry { return value["name"]?.stringValue }
            return nil
        }
        #expect(names == ["sin fecha", "dos"])
    }

    @Test("Una versión futura se lee pero no se escribe, con un mensaje para actualizar")
    func futureVersion() throws {
        let text = "{\"version\": 2, \"projects\": [{\"id\": \"11111111-1111-1111-1111-111111111111\", \"name\": \"uno\", \"path\": \"/a\", \"createdAt\": \"2025-11-07T10:00:00Z\"}]}"
        let document = try ProjectsDocument.parse(text)
        #expect(document.projects.count == 1)
        #expect(ProjectsLoadReport(document: document).warning?.contains("Actualiza Argos") == true)
        #expect(throws: ProjectError.newerFormat(2)) { try document.replacingProjects([]) }
        #expect(ProjectError.newerFormat(2).errorDescription?.contains("Actualiza Argos en este dispositivo") == true)
    }

    @Test("El mensaje de archivo dañado dice qué hacer")
    func invalidFileMessage() {
        let message = ProjectError.invalidFile.errorDescription ?? ""
        #expect(message.contains("no lo ha modificado"))
        #expect(message.contains(".argos-backup"))
    }
}

@Suite("projects.json: escritura con huella")
struct ProjectsUpdaterTests {

    /// Servidor de mentira: un texto y una huella que se comprueba al escribir.
    private actor FakeFile {
        var text: String
        var writes = 0
        /// Cambios ajenos que «otro dispositivo» hace justo después de cada lectura.
        var interference: [String]

        init(text: String, interference: [String] = []) {
            self.text = text
            self.interference = interference
        }

        func read() -> String {
            let current = text
            if !interference.isEmpty { text = interference.removeFirst() }
            return current
        }

        func write(_ data: Data, expected: String?) -> ProjectsWriteOutcome {
            guard ProjectsUpdater.expectedFingerprint(of: text) == expected else { return .conflict }
            text = String(decoding: data, as: UTF8.self)
            writes += 1
            return .written
        }
    }

    private static func file(_ names: [String]) throws -> String {
        let projects = names.enumerated().map { index, name in
            Project(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!, name: name, path: "/\(name)",
                    createdAt: Date(timeIntervalSince1970: 1_000))
        }
        return String(decoding: try ProjectsFile(projects: projects).encoded(), as: UTF8.self)
    }

    private static func append(_ name: String) -> @Sendable ([Project]) -> [Project] {
        { $0 + [Project(name: name, path: "/\(name)", createdAt: Date(timeIntervalSince1970: 2_000))] }
    }

    @Test("Si otro dispositivo escribe entre la lectura y el mv, se relee y se reaplica el cambio")
    func conflictRetries() async throws {
        let fake = FakeFile(text: try Self.file(["a"]), interference: [try Self.file(["a", "b"])])
        let report = try await ProjectsUpdater.run(
            read: { await fake.read() },
            write: { data, expected in await fake.write(data, expected: expected) },
            transform: Self.append("c")
        )
        #expect(report.projects.map(\.name) == ["a", "b", "c"])
        #expect(try ProjectsDocument.parse(await fake.text).projects.map(\.name) == ["a", "b", "c"])
        #expect(await fake.writes == 1)
    }

    @Test("Si el archivo no deja de cambiar, se rinde con un error claro sin escribir")
    func persistentConflict() async throws {
        let changes = try (0..<ProjectsUpdater.maxAttempts).map { try Self.file(["x\($0)"]) }
        let fake = FakeFile(text: try Self.file(["a"]), interference: changes)
        await #expect(throws: ProjectError.writeConflict) {
            _ = try await ProjectsUpdater.run(
                read: { await fake.read() },
                write: { data, expected in await fake.write(data, expected: expected) },
                transform: Self.append("c")
            )
        }
        #expect(await fake.writes == 0)
    }

    @Test("Archivo inexistente: se espera vacío; sin cambios no se escribe")
    func absentAndNoop() async throws {
        #expect(ProjectsUpdater.expectedFingerprint(of: "") == nil)
        let fake = FakeFile(text: "")
        _ = try await ProjectsUpdater.run(
            read: { await fake.read() },
            write: { data, expected in await fake.write(data, expected: expected) },
            transform: Self.append("a")
        )
        #expect(await fake.writes == 1)
        _ = try await ProjectsUpdater.run(
            read: { await fake.read() },
            write: { data, expected in await fake.write(data, expected: expected) },
            transform: { $0 }
        )
        #expect(await fake.writes == 1)
    }

    @Test("La huella coincide con el cksum de POSIX")
    func posixChecksum() {
        #expect(PosixChecksum.fingerprint(of: Data()) == "4294967295 0")
        #expect(PosixChecksum.fingerprint(of: Data("a".utf8)) == "1220704766 1")
        #expect(PosixChecksum.fingerprint(of: Data("ñandú 123456789".utf8)) == "2402627206 17")
    }

    @Test("La fila serializa las operaciones de una misma clave")
    func serialQueue() async throws {
        let queue = SerialQueue()
        let log = Recorder()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask {
                    _ = try? await queue.run(key: "s") {
                        await log.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await log.leave(index)
                    }
                }
            }
        }
        #expect(await log.maxConcurrent == 1)
        #expect(await log.finished.count == 5)
    }

    private actor Recorder {
        var active = 0, maxConcurrent = 0
        var finished: [Int] = []
        func enter() { active += 1; maxConcurrent = max(maxConcurrent, active) }
        func leave(_ index: Int) { active -= 1; finished.append(index) }
    }
}

@Suite("Escritura privada en $HOME (script real con sh)")
struct HomeFileScriptsTests {

    private static let path = ".config/argos/projects.json"

    private func write(_ text: String, home: URL, expectation: HomeFileExpectation, backup: String? = ".argos-backup") throws -> Int32 {
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let prepare = try LocalShell.run(ShellQuoting.posixShell(HomeFileScripts.prepare(Self.path, token: token)), home: home)
        #expect(prepare.exitCode == 0)
        #expect(prepare.stdout == home.path)
        let temporary = home.appendingPathComponent(Self.path + HomeFileScripts.temporarySuffix(token: token))
        try Data(text.utf8).write(to: temporary)
        let script = HomeFileScripts.commit(Self.path, token: token, expectation: expectation, backupSuffix: backup)
        let result = try LocalShell.run(ShellQuoting.posixShell(script), home: home)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        return result.exitCode
    }

    private func contents(_ home: URL, _ suffix: String = "") -> String? {
        try? String(contentsOf: home.appendingPathComponent(Self.path + suffix), encoding: .utf8)
    }

    @Test("Escribe si la huella coincide, deja copia y rechaza si cambió")
    func compareAndSwap() throws {
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        #expect(try write("uno", home: home, expectation: .absentOrEmpty) == 0)
        #expect(contents(home) == "uno")
        #expect(try write("dos", home: home, expectation: .absentOrEmpty) == Int32(HomeFileScripts.conflictExitCode))
        #expect(contents(home) == "uno")

        let fingerprint = PosixChecksum.fingerprint(of: Data("uno".utf8))
        #expect(try write("dos", home: home, expectation: .fingerprint(fingerprint)) == 0)
        #expect(contents(home) == "dos")
        #expect(contents(home, ".argos-backup") == "uno")
        #expect(try write("tres", home: home, expectation: .fingerprint(fingerprint)) == Int32(HomeFileScripts.conflictExitCode))
        #expect(contents(home) == "dos")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(Self.path + ".argos-lock").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(Self.path).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("No reemplaza un enlace simbólico ni escribe a través de una copia que sea un enlace")
    func symlinks() throws {
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        let directory = home.appendingPathComponent(".config/argos")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = home.appendingPathComponent("fuera.txt")
        try Data("intacto".utf8).write(to: outside)
        // La copia apunta fuera: se recrea, sin escribir a través del enlace.
        try Data("viejo".utf8).write(to: directory.appendingPathComponent("projects.json"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("projects.json.argos-backup"), withDestinationURL: outside)
        #expect(try write("nuevo", home: home, expectation: .any) == 0)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "intacto")
        #expect(contents(home, ".argos-backup") == "viejo")

        // El propio archivo es un enlace: no se toca.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("projects.json"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("projects.json"), withDestinationURL: outside)
        #expect(try write("otro", home: home, expectation: .any) == Int32(HomeFileScripts.symlinkExitCode))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "intacto")
    }

    @Test("Un cerrojo abandonado (más de un minuto) se recupera")
    func lock() throws {
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        let lock = home.appendingPathComponent(Self.path + ".argos-lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        // Abandonado hace 5 minutos: se recupera.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: lock.path)
        #expect(try write("uno", home: home, expectation: .any) == 0)
        #expect(contents(home) == "uno")
    }

    @Test("Solo admite rutas fijas y simples")
    func safePaths() {
        #expect(HomeFileScripts.isSafe(".config/argos/projects.json"))
        #expect(HomeFileScripts.isSafe(".claude/settings.json"))
        #expect(!HomeFileScripts.isSafe("../etc/passwd"))
        #expect(!HomeFileScripts.isSafe("/etc/passwd"))
        #expect(!HomeFileScripts.isSafe("a\"; rm -rf ~; \".json"))
        #expect(!HomeFileScripts.isSafe("$(id).json"))
    }
}
