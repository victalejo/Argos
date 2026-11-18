//
//  IntegrationProjectsFileTests.swift
//  ArgosTests
//
//  `~/.config/argos/projects.json` en un servidor real (`HomeFileScripts`,
//  `ProjectsUpdater`): crear, actualizar conservando lo desconocido, conflicto entre
//  escritores (código 75), cerrojo ocupado / abandonado, enlace simbólico (77), copia
//  `.argos-backup` + restaurar y entradas dañadas. Ver `IntegrationRemote`.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("projects.json en el servidor")
struct ProjectsFile {

    private static let path = SSHService.projectsRelativePath
    private static let lock = "$HOME/\(SSHService.projectsRelativePath).argos-lock"

    /// Conexión con projects.json (y sus copias, cerrojo y temporales) borrados.
    private func freshBox() async throws -> RemoteBox {
        let box = try await RemoteBox.open("projects")
        try await box.sh("rm -rf \"$HOME/\(Self.path)\" \"$HOME/\(Self.path)\".argos-*")
        return box
    }

    private func raw(_ box: RemoteBox, suffix: String = "") async throws -> String {
        try await box.read("\(box.home)/\(Self.path)\(suffix)")
    }

    private func project(_ name: String) -> Project {
        Project(name: name, path: "/srv/\(name)", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Crea el archivo (600) y al actualizar conserva claves desconocidas y deja copia", .timeLimit(.minutes(2)))
    func createAndUpdateKeepsUnknownKeys() async throws {
        let box = try await freshBox()
        defer { IntegrationCleanup.later { await box.close() } }

        try await box.service.saveProjects([project("uno")])
        let created = try await box.service.loadProjects()
        #expect(created.map(\.name) == ["uno"])
        let mode = try await box.sh("ls -l \"$HOME/\(Self.path)\" | cut -c1-10")
        #expect(mode.trimmingCharacters(in: .whitespacesAndNewlines) == "-rw-------")

        // Otra versión de Argos añadió claves que esta no conoce (archivo y proyecto).
        let id = created[0].id.uuidString
        try await box.write("""
        {"futuro":{"x":1},"projects":[{"createdAt":"2023-11-14T22:13:20Z","id":"\(id)",\
        "name":"uno","path":"/srv/uno","colorFuturo":"rojo"}],"version":1}
        """, to: "\(box.home)/\(Self.path)")

        let report = try await box.service.updateProjects { $0 + [self.project("dos")] }
        #expect(report.projects.map(\.name) == ["uno", "dos"])
        let text = try await raw(box)
        #expect(text.contains("\"futuro\""))
        #expect(text.contains("\"colorFuturo\" : \"rojo\"") || text.contains("\"colorFuturo\":\"rojo\""))
        let backup = try await raw(box, suffix: SSHService.projectsBackupSuffix)
        #expect(backup.contains("colorFuturo") && !backup.contains("\"dos\""), "La copia es la versión anterior")
        // Sin temporales ni cerrojo colgando.
        let leftovers = try await box.sh("ls -a \"$HOME/.config/argos\" | grep -E 'argos-(tmp|lock)' ; true")
        #expect(leftovers.isEmpty)
    }

    @Test("Si otro escritor cambia el archivo entre la lectura y la escritura, se relee y se reaplica (75)",
          .timeLimit(.minutes(2)))
    func conflictRereadsAndReapplies() async throws {
        let box = try await freshBox()
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.service.saveProjects([project("base")])

        // Escritura directa con una huella vieja: el servidor dice «conflicto» sin escribir.
        let before = try await raw(box)
        let stale = try #require(ProjectsUpdater.expectedFingerprint(of: before + " "))
        let outcome = try await box.service.writeHomeFile(
            Data("{}".utf8), to: Self.path, expecting: .fingerprint(stale), backupSuffix: nil
        )
        #expect(outcome == .conflict)
        #expect(try await raw(box) == before)

        // Flujo completo: tras la PRIMERA lectura, otro dispositivo añade «ajeno».
        let reads = IntegrationCounter()
        let service = box.service
        let report = try await ProjectsUpdater.run(
            read: {
                let text = try await service.readHomeFile(Self.path)
                if await reads.increment() == 1 {
                    _ = try await service.updateProjects { $0 + [self.project("ajeno")] }
                }
                return text
            },
            write: { data, expected in
                try await service.writeHomeFile(
                    data, to: Self.path, expecting: HomeFileExpectation(expected: expected),
                    backupSuffix: SSHService.projectsBackupSuffix
                )
            },
            transform: { $0 + [self.project("mio")] }
        )
        #expect(await reads.value == 2, "Debe releer una vez tras el conflicto")
        #expect(report.projects.map(\.name) == ["base", "ajeno", "mio"])
        #expect(try await box.service.loadProjects().map(\.name) == ["base", "ajeno", "mio"])
    }

    @Test("Cerrojo ocupado: avisa sin escribir; cerrojo abandonado (> 1 min): se retira y escribe",
          .timeLimit(.minutes(2)))
    func busyAndAbandonedLock() async throws {
        let box = try await freshBox()
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.service.saveProjects([project("antes")])

        try await box.sh("mkdir \"\(Self.lock)\"")
        await #expect(throws: HomeFileError.locked(Self.path)) {
            try await box.service.saveProjects([self.project("despues")])
        }
        #expect(try await box.service.loadProjects().map(\.name) == ["antes"])
        #expect(try await box.exists("\(box.home)/\(Self.path).argos-lock"), "El cerrojo ajeno no se toca")

        // Mismo cerrojo, pero de hace dos horas: un guardado interrumpido.
        try await box.sh("touch -t 200001010000 \"\(Self.lock)\"")
        try await box.service.saveProjects([project("despues")])
        #expect(try await box.service.loadProjects().map(\.name) == ["despues"])
        #expect(try await box.exists("\(box.home)/\(Self.path).argos-lock") == false)
    }

    @Test("Un projects.json que es un enlace simbólico no se reemplaza (77)", .timeLimit(.minutes(1)))
    func symlinkIsRejected() async throws {
        let box = try await freshBox()
        defer { IntegrationCleanup.later { await box.close() } }
        let target = "\(box.root)/real.json"
        try await box.write("{\"version\":1,\"projects\":[]}", to: target)
        try await box.sh("mkdir -p \"$HOME/.config/argos\" && ln -s \(box.q(target)) \"$HOME/\(Self.path)\"")

        await #expect(throws: HomeFileError.symlink(Self.path)) {
            try await box.service.saveProjects([self.project("x")])
        }
        #expect(try await box.read(target) == "{\"version\":1,\"projects\":[]}", "El destino del enlace sigue intacto")
        let link = try await box.sh("[ -L \"$HOME/\(Self.path)\" ] && echo enlace; true")
        #expect(link.contains("enlace"))
    }

    @Test("Restaurar la copia: el dañado queda en .argos-damaged; sin copia, avisa", .timeLimit(.minutes(1)))
    func restoreBackup() async throws {
        let box = try await freshBox()
        defer { IntegrationCleanup.later { await box.close() } }

        await #expect(throws: ProjectError.noBackup) { _ = try await box.service.restoreProjectsBackup() }

        try await box.service.saveProjects([project("bueno")])
        try await box.service.saveProjects([project("bueno"), project("segundo")])
        // Se estropea el archivo actual (p. ej. un editor a medias).
        try await box.write("{ roto", to: "\(box.home)/\(Self.path)")
        await #expect(throws: ProjectError.invalidFile) { _ = try await box.service.loadProjects() }

        let report = try await box.service.restoreProjectsBackup()
        #expect(report.projects.map(\.name) == ["bueno"])
        #expect(try await box.service.loadProjects().map(\.name) == ["bueno"])
        #expect(try await raw(box, suffix: SSHService.projectsDamagedSuffix) == "{ roto")
    }

    @Test("Una entrada dañada se aparta, se avisa y se conserva al reescribir", .timeLimit(.minutes(1)))
    func damagedEntryIsKept() async throws {
        let box = try await freshBox()
        defer { IntegrationCleanup.later { await box.close() } }
        let good = project("sano")
        try await box.write("""
        {"projects":[{"createdAt":"2023-11-14T22:13:20Z","id":"\(good.id.uuidString)","name":"sano","path":"/srv/sano"},\
        {"name":"sin-fecha","path":"/srv/x"}],"version":1}
        """, to: "\(box.home)/\(Self.path)")

        let report = try await box.service.loadProjectsReport()
        #expect(report.projects.map(\.name) == ["sano"])
        #expect(report.skippedEntries == 1)
        #expect(report.warning != nil)

        _ = try await box.service.updateProjects { $0 + [self.project("nuevo")] }
        let text = try await raw(box)
        #expect(text.contains("sin-fecha"), "La entrada ilegible se reescribe tal cual")
        let after = try await box.service.loadProjectsReport()
        #expect(after.projects.map(\.name) == ["sano", "nuevo"])
        #expect(after.skippedEntries == 1)
    }
}

}

/// Contador compartido entre closures `@Sendable`.
actor IntegrationCounter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
