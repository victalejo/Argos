//
//  IntegrationCheckpointSafetyTests.swift
//  ArgosTests
//
//  La regla central de los puntos de restauración contra un servidor real («al restaurar,
//  nada se sobrescribe ni se borra si su contenido actual no está en la copia previa»):
//  repositorios anidados, carpetas con ignorados, `.env` ignorado después, marcas del
//  índice, «racy git», puntos dañados por `gc`, permisos 0600, enlaces y nombres hostiles.
//  Son los escenarios de `CheckpointSafetyTests`/`CheckpointHardeningTests`, pero por SSH
//  y con las utilidades del servidor (dash, coreutils de GNU o uutils, findutils…).
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Puntos de restauración en el servidor: seguridad")
struct CheckpointSafety {

    /// Nombres que rompen un entrecomillado descuidado.
    private static let oddNames = [
        "con espacio.txt", "acentuado ñandú.txt", "comilla'simple.txt", "comilla\"doble.txt",
        "salto\nde línea.txt", "-empieza-por-guion.txt", "dólar $HOME y `x`.txt",
    ]

    private func nestedRepository(_ repo: RemoteCheckpointRepo, at path: String) async throws {
        try await repo.sh("git init -q \(repo.q(path)) && cd \(repo.q(path)) && git config user.email t@t && "
            + "git config user.name t && echo trabajo > x.c && git add x.c && git commit -qm x && echo SIN_COMMIT > y.c")
    }

    @Test("Un repositorio anidado o una carpeta con ignorados donde el punto tenía un archivo no se tocan", .timeLimit(.minutes(3)))
    func directoriesInTheWay() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cps-nested") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.write("lib", "v1\n")
        try await repo.write("config", "cfg=1\n")
        let point = try await repo.snapshot()
        try await repo.sh("rm lib config")
        try await nestedRepository(repo, at: "lib")
        try await repo.write(".gitignore", "*.local\n")
        try await repo.write("config/visible.txt", "keep\n")
        try await repo.write("config/db.local", "SECRETO\n")

        guard case .ready(let preview) = try CheckpointParser.parsePreview(try await repo.preview(point),
                                                                           checkpoint: CheckpointScriptTests.sample(point)) else {
            Issue.record("sin vista previa"); return
        }
        #expect(preview.conflicts.contains(CheckpointIssue(kind: .directoryInTheWay, path: "lib")))
        #expect(preview.conflicts.contains(CheckpointIssue(kind: .directoryInTheWay, path: "config")))
        #expect(!preview.canRestore)
        let result = try await repo.restore(point)
        guard case .conflict = try CheckpointParser.parseRestore(result) else {
            Issue.record("debería negarse: \(result)"); return
        }
        #expect(try await repo.read("lib/y.c") == "SIN_COMMIT\n")
        #expect(try await repo.exists("lib/.git/HEAD"))
        #expect(try await repo.read("config/db.local") == "SECRETO\n")
        #expect(try await repo.read("config/visible.txt") == "keep\n")
        #expect(try await repo.restoreFile(point, "config").contains("ARGOS_CP_NOOP D"))
        #expect(try await repo.restoreFile(point, "lib").contains("ARGOS_CP_NOOP"))
        #expect(try await repo.read("lib/y.c") == "SIN_COMMIT\n")
    }

    @Test("Un .env capturado y luego ignorado no se sobrescribe; la vista previa lo dice", .timeLimit(.minutes(2)))
    func ignoredLater() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cps-env") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.write(".env", "VIEJO\n")
        let point = try await repo.snapshot()
        try await repo.write(".gitignore", ".env\n")
        try await repo.write(".env", "NUEVO\n")
        guard case .ready(let preview) = try CheckpointParser.parsePreview(try await repo.preview(point),
                                                                           checkpoint: CheckpointScriptTests.sample(point)) else {
            Issue.record("sin vista previa"); return
        }
        #expect(preview.untouched == [".env"] && preview.canRestore)
        let result = try await repo.restore(point)
        #expect(result.contains("ARGOS_CP_PARTIAL"), "\(result)")
        #expect(try await repo.read(".env") == "NUEVO\n")
        #expect(try await !repo.exists(".gitignore"))
    }

    @Test("skip-worktree y assume-unchanged: la copia previa guarda lo del disco (todo y un archivo)", .timeLimit(.minutes(3)))
    func indexFlags() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cps-flags") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.write("s.txt", "orig\n")
        try await repo.write("c.txt", "orig\n")
        try await repo.sh("git add -A && git commit -qm s")
        let point = try await repo.snapshot()
        try await repo.write("s.txt", "turno\n")
        try await repo.write("c.txt", "turno\n")
        try await repo.sh("git commit -qam t && git update-index --skip-worktree s.txt && git update-index --assume-unchanged c.txt")
        try await repo.write("s.txt", "VALIOSO-S\n")
        try await repo.write("c.txt", "VALIOSO-C\n")
        try await repo.restore(point)
        #expect(try await repo.inLatest("s.txt") == "VALIOSO-S\n")
        #expect(try await repo.inLatest("c.txt") == "VALIOSO-C\n")
        #expect(try await repo.read("s.txt") == "orig\n")
        #expect(try await repo.read("c.txt") == "orig\n")

        try await repo.write("s.txt", "VALIOSO-2\n")
        #expect(try await repo.restoreFile(point, "s.txt").contains("ARGOS_CP_DONE"))
        #expect(try await repo.inLatest("s.txt") == "VALIOSO-2\n")
        #expect(try await repo.read("s.txt") == "orig\n")
    }

    @Test("racy git: un cambio del mismo segundo y tamaño llega a la copia previa", .timeLimit(.minutes(3)))
    func racyGit() async throws {
        for round in 0..<3 {
            guard let repo = try await RemoteCheckpointRepo.open("cps-racy\(round)") else { return }
            defer { IntegrationCleanup.later { await repo.close() } }
            try await repo.write("r", "v0\n")
            try await repo.sh("git add -A && git commit -qm i0")
            let point = try await repo.snapshot()
            try await repo.sh("echo v1 > r && git commit -qam i1 && echo v2 > r && sleep 1")
            let result = try await repo.restore(point)
            #expect(try await repo.inLatest("r") == "v2\n", "ronda \(round): \(result)")
            #expect(try await repo.read("r") == "v0\n")
        }
    }

    @Test("gc --prune=now del principal: el punto sellado sobrevive; el no sellado se marca y no toca nada", .timeLimit(.minutes(3)))
    func garbageCollection() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cps-gc") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        try await repo.write("a.txt", "SOLO-EN-EL-INDICE\n")
        try await repo.sh("git add a.txt")
        try await repo.hook(prompt: "sellado")
        let sealed = try #require(try await repo.points().first)
        #expect(try await repo.waitSealed(sealed))
        try await repo.write("a.txt", "SIN-SELLAR\n")
        try await repo.sh("git add a.txt")
        let unsealedOutput = try await repo.box.service.runCheckpointCommand(
            "ARGOS_CP_TEST_NO_SEAL=1 " + CheckpointCommands.snapshot(root: repo.path, label: "sin sellar")).stdout
        let unsealed = try #require(try CheckpointParser.parseSnapshot(unsealedOutput))
        try await repo.sh("git reset -q --hard && git gc -q --prune=now")
        try await repo.write("b.txt", "nuevo\n")

        let listing = try await repo.list()
        #expect(listing.checkpoints.first { $0.commit == sealed }?.isDamaged == false)
        #expect(listing.checkpoints.first { $0.commit == unsealed }?.isDamaged == true)
        let preview = try await repo.preview(unsealed)
        #expect(throws: CheckpointError.damaged) {
            try CheckpointParser.parsePreview(preview, checkpoint: CheckpointScriptTests.sample(unsealed))
        }
        let full = try await repo.command(CheckpointCommands.restore(root: repo.path, commit: unsealed, expectedTree: nil, path: nil))
        #expect(throws: CheckpointError.damaged) { try CheckpointParser.parseRestore(full) }
        let one = try await repo.restoreFile(unsealed, "a.txt")
        #expect(throws: CheckpointError.damaged) { try CheckpointParser.parseRestore(one) }
        #expect(try await repo.read("a.txt") == "base\n")
        #expect(try await repo.read("b.txt") == "nuevo\n")

        #expect(try await repo.restoreFile(sealed, "a.txt").contains("ARGOS_CP_DONE"))
        #expect(try await repo.read("a.txt") == "SOLO-EN-EL-INDICE\n")
    }

    @Test("Un archivo sin seguimiento con permisos 0600 no se borra; un enlace no hace escribir fuera", .timeLimit(.minutes(2)))
    func permissionsAndSymlinks() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cps-perm") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.write("out/f.txt", "del punto\n")
        try await repo.write("enlace", "archivo\n")
        let point = try await repo.snapshot()
        try await repo.write("clave.pem", "SECRETA\n")
        try await repo.sh("chmod 600 clave.pem")
        let result = try await repo.restore(point)
        #expect(try CheckpointParser.parseRestore(result) == .conflict([CheckpointIssue(kind: .permissions, path: "clave.pem")]))
        #expect(try await repo.read("clave.pem") == "SECRETA\n")
        try await repo.sh("rm clave.pem")

        try await repo.sh("mkdir -p ../fuera && echo IMPORTANTE > ../fuera/f.txt && rm -r out enlace && ln -s ../fuera out "
            + "&& ln -s a.txt enlace")
        let second = try await repo.restore(point)
        #expect(try await repo.box.read(repo.zone + "/fuera/f.txt") == "IMPORTANTE\n", "\(second)")
        #expect(try await repo.sh("[ -L enlace ] && echo enlace; true").isEmpty, "el enlace del punto volvió a ser archivo")
        #expect(try await repo.read("enlace") == "archivo\n")
    }

    @Test("Restaurar todo y un archivo con nombres con espacios, acentos, comillas y salto de línea", .timeLimit(.minutes(3)))
    func oddNames() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cps-names") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        for name in Self.oddNames { try await repo.write(name, "v1\n") }
        try await repo.hook(prompt: "nombres")
        let point = try #require(try await repo.points().first)
        for name in Self.oddNames {
            #expect(try await repo.show(point, name) == "v1\n", "\(name)")
            try await repo.write(name, "v2\n")
        }
        try await repo.write("dir con espacio/extra ñ.txt", "extra\n")

        let preview = try await repo.preview(point)
        guard case .ready(let parsed) = try CheckpointParser.parsePreview(preview, checkpoint: CheckpointScriptTests.sample(point)) else {
            Issue.record("sin vista previa"); return
        }
        #expect(Set(parsed.toModify) == Set(Self.oddNames))
        #expect(parsed.toDelete == ["dir con espacio/extra ñ.txt"])
        let result = try await repo.restore(point)
        #expect(try CheckpointParser.parseRestore(result) == .done(backup: try await repo.points().first))
        for name in Self.oddNames { #expect(try await repo.read(name) == "v1\n", "\(name)") }
        #expect(try await !repo.exists("dir con espacio/extra ñ.txt"))
        #expect(try await repo.inLatest("dir con espacio/extra ñ.txt") == "extra\n")

        let newline = "salto\nde línea.txt"
        try await repo.write(newline, "v3\n")
        try await repo.write("con espacio.txt", "v3\n")
        #expect(try await repo.restoreFile(point, newline).contains("ARGOS_CP_DONE"))
        #expect(try await repo.read(newline) == "v1\n")
        #expect(try await repo.read("con espacio.txt") == "v3\n")
        let diff = try await repo.command(CheckpointCommands.diff(root: repo.path, from: point, to: "-", path: "con espacio.txt"))
        #expect(diff.contains("-v1") && diff.contains("+v3"))
    }
}
}
