//
//  CheckpointSafetyTests.swift
//  ArgosTests
//
//  Reproducciones de la revisión independiente (t1…t10), convertidas en tests que
//  ejecutan el script real con /bin/sh y dash: restaurar nunca pierde datos que no estén en
//  la copia previa, el hook no se dispara el tiempo ni el disco, y no rompe permisos.
//

import Foundation
import Testing
@testable import Argos

@Suite("Checkpoint · seguridad", .serialized)
struct CheckpointSafetyTests {

    private func makeRepo(_ shell: String) throws -> CheckpointRepo {
        let repo = try CheckpointRepo(shell: shell)
        try repo.write("a", "a\n")
        try repo.git("add -A && git commit -qm init")
        return repo
    }

    /// Repo anidado con historial y trabajo sin commit en `path`.
    private func makeNestedRepo(_ repo: CheckpointRepo, at path: String, content: String = "trabajo") throws {
        try repo.sh("""
        git init -q \(path) && cd \(path) && git config user.email t@t && git config user.name t \
        && echo \(content) > x.c && git add x.c && git commit -qm x && echo SIN_COMMIT > y.c
        """)
    }

    private func issues(_ output: String) -> [CheckpointIssue] {
        CheckpointParser.parseIssues(output, after: "ARGOS_CP_CONFLICT\n")
    }

    @Test("t2 C / t3: un repositorio anidado donde el punto tenía un archivo no se borra",
          arguments: CheckpointRepo.shells)
    func nestedRepositoryAtFilePath(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("lib", "v1\n")
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.remove("lib")
        try makeNestedRepo(repo, at: "lib")
        try repo.hook(prompt: "t2")

        let preview = try repo.checkpoint(["preview", repo.repo.path, point, "full"]).stdout
        guard case .ready(let parsed) = try CheckpointParser.parsePreview(preview, checkpoint: CheckpointScriptTests.sample(point)) else {
            Issue.record("sin vista previa"); return
        }
        #expect(parsed.conflicts.contains(CheckpointIssue(kind: .directoryInTheWay, path: "lib")))
        #expect(!parsed.canRestore)

        let result = try repo.restore(point)
        #expect(try CheckpointParser.parseRestore(result) == .conflict([CheckpointIssue(kind: .directoryInTheWay, path: "lib")]))
        #expect(repo.read("lib/y.c") == "SIN_COMMIT\n")
        #expect(repo.exists("lib/.git/HEAD"))
        #expect(try repo.sh("cd lib && git log --oneline | wc -l").stdout.trimmingCharacters(in: .whitespaces) == "1\n")
    }

    @Test("t2 B / t8 Q: una carpeta con archivos ignorados donde el punto tenía un archivo",
          arguments: CheckpointRepo.shells)
    func ignoredFilesInDirectoryAtFilePath(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("config", "cfg=1\n")
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.remove("config")
        try repo.write("config/visible.txt", "keep\n")
        try repo.write(".gitignore", "*.local\n")
        try repo.write("config/db.local", "SECRETO\n")
        try repo.hook(prompt: "t2")

        let result = try repo.restore(point)
        #expect(issues(result).contains(CheckpointIssue(kind: .directoryInTheWay, path: "config")))
        #expect(repo.read("config/db.local") == "SECRETO\n")
        #expect(repo.read("config/visible.txt") == "keep\n")

        let one = try repo.checkpoint(["restore", repo.repo.path, point, "-", "config"]).stdout
        #expect(one.contains("ARGOS_CP_NOOP D"))
        #expect(repo.read("config/db.local") == "SECRETO\n")
    }

    @Test("t2 D / t4: una carpeta del punto que hoy es un repositorio anidado no se sobrescribe",
          arguments: CheckpointRepo.shells)
    func nestedRepositoryAtDirectory(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("vendor/x.c", "v1\n")
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.remove("vendor")
        try makeNestedRepo(repo, at: "vendor", content: "base")
        try repo.write("vendor/x.c", "CAMBIO_LOCAL\n")
        try repo.hook(prompt: "t2")

        let result = try repo.restore(point)
        #expect(issues(result).contains(CheckpointIssue(kind: .nestedRepository, path: "vendor/x.c")))
        #expect(repo.read("vendor/x.c") == "CAMBIO_LOCAL\n")
        #expect(repo.read("vendor/y.c") == "SIN_COMMIT\n")
    }

    @Test("t1: un .env capturado y luego ignorado no se sobrescribe; la vista previa lo dice",
          arguments: CheckpointRepo.shells)
    func ignoredLaterIsNotOverwritten(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write(".env", "OLDSECRET\n")
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.remove(".env")
        try repo.hook(prompt: "t2")
        try repo.write(".gitignore", ".env\n")
        try repo.write(".env", "NEWSECRET\n")

        let preview = try repo.checkpoint(["preview", repo.repo.path, point, "full"]).stdout
        guard case .ready(let parsed) = try CheckpointParser.parsePreview(preview, checkpoint: CheckpointScriptTests.sample(point)) else {
            Issue.record("sin vista previa"); return
        }
        #expect(parsed.untouched == [".env"])
        #expect(parsed.canRestore)
        let result = try repo.restore(point)
        #expect(result.contains("ARGOS_CP_PARTIAL"))
        #expect(repo.read(".env") == "NEWSECRET\n")
    }

    @Test("t10 / t2 A: los índices privados no divergen ni arrastran archivos ya ignorados",
          arguments: CheckpointRepo.shells)
    func privateIndexesStayConsistent(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.checkpoint(["list", repo.repo.path])
        try repo.write(".env", "S\n")
        try repo.write("a", "cambio\n")
        try repo.hook(prompt: "t2")
        try repo.write(".gitignore", ".env\n")
        try repo.write("b", "otro\n")
        try repo.hook(prompt: "t3")
        let latest = try #require(try repo.points().first)
        #expect(!(try repo.files(of: latest)).contains(".env"), "un archivo ya ignorado no se sigue capturando")
        for _ in 0..<3 {
            let result = try repo.restore(point)
            #expect(!result.contains("ARGOS_CP_CHANGED"))
        }
        #expect(repo.read("a") == "a\n")
        // Lo que se borró al restaurar (el .env ya sin ignorar) está en una copia previa.
        let saved = try repo.points().contains { (try? repo.show($0, ".env")) == "S\n" }
        #expect(saved || repo.read(".env") == "S\n")
    }

    @Test("t6: un archivo seguido que crece no retrasa el hook ni hincha .git")
    func bigTrackedFile() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.write("data.db", "small\n")
        try repo.git("add data.db && git commit -qm db")
        try repo.hook()
        try repo.sh("dd if=/dev/zero of=data.db bs=1048576 count=30 2>/dev/null")
        let elapsed = try repo.timedHook(prompt: "grande")
        #expect(elapsed < 3, "el hook tardó \(elapsed) s")
        #expect(try repo.points().count == 1)
        let size = try repo.sh("du -sk .git | cut -f1").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((Int(size) ?? 0) < 10_000, ".git ocupa \(size) KB")
        guard case .listing(let listing) = try CheckpointParser.parseList(try repo.checkpoint(["list", repo.repo.path]).stdout) else {
            Issue.record("sin lista"); return
        }
        #expect(listing.skips.last?.reason.contains("20 MB") == true)
    }

    @Test("Un hook normal cuesta poco", arguments: CheckpointRepo.shells)
    func normalHookIsFast(shell: String) throws {
        let repo = try makeRepo(shell)
        for index in 0..<50 { try repo.write("src/f\(index).swift", "// \(index)\n") }
        try repo.git("add -A && git commit -qm src")
        try repo.write("src/f1.swift", "// cambio\n")
        let first = try repo.timedHook()
        try repo.write("src/f2.swift", "// cambio\n")
        let second = try repo.timedHook(prompt: String(repeating: "x", count: 200_000))
        #expect(first < 2 && second < 2, "hook: \(first) s y \(second) s")
        #expect(try repo.points().count == 2)
    }

    @Test("t9: el hook no cambia los permisos de .git en un repositorio compartido por grupo")
    func groupSharedRepository() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.git("config core.sharedRepository group")
        let before = try repo.sh("find .git/objects -type d | sort").stdout
        try repo.write("b", "contenido-unico-\(UUID().uuidString)\n")
        try repo.sh("umask 002; true")
        try repo.hook()
        #expect(try repo.points().count == 1)
        #expect(try repo.sh("find .git/objects -type d | sort").stdout == before, "no escribe en objects/ del repositorio")
        let mode = try repo.sh("ls -ld .git/\(CheckpointScript.storeName) | cut -c1-10").stdout
        #expect(mode.hasPrefix("drwx------"))
    }

    @Test("t5 G / t8 O: restaurar un archivo con .., ruta absoluta, ignorado o repo anidado: «nada»",
          arguments: CheckpointRepo.shells)
    func restoreOneRefusesOddPaths(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.hook()
        let point = try #require(try repo.points().first)
        for path in ["../../etc/passwd", "/etc/hosts", "a/../a", "."] {
            let result = try repo.checkpoint(["restore", repo.repo.path, point, "-", path]).stdout
            #expect(try CheckpointParser.parseRestore(result) == .nothing(CheckpointParser.noopText("invalid")), "\(path)")
        }
        try makeNestedRepo(repo, at: "lib")
        let nested = try repo.checkpoint(["restore", repo.repo.path, point, "-", "lib"]).stdout
        #expect(nested.contains("ARGOS_CP_NOOP"))
        #expect(repo.read("lib/y.c") == "SIN_COMMIT\n")
        try repo.restore(point)
        #expect(repo.exists("lib/.git/HEAD"))
        #expect(repo.read("lib/y.c") == "SIN_COMMIT\n")
    }

    @Test("t5 F: un enlace a una carpeta de fuera no hace escribir fuera del repositorio")
    func symlinkOutside() throws {
        let repo = try makeRepo("/bin/sh")
        let outside = repo.base.appendingPathComponent("fuera", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "IMPORTANTE\n".write(to: outside.appendingPathComponent("f.txt"), atomically: false, encoding: .utf8)
        try repo.write("out/f.txt", "del punto\n")
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.remove("out")
        try repo.sh("ln -s \(ShellQuoting.singleQuoted(outside.path)) out")
        try repo.hook(prompt: "t2")
        try repo.restore(point)
        #expect(try String(contentsOf: outside.appendingPathComponent("f.txt"), encoding: .utf8) == "IMPORTANTE\n")
    }

    @Test("Candado vivo: no se rompe; uno de un proceso muerto, sí")
    func locks() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.write("a", "x\n")
        try repo.hook()
        let lock = repo.store.appendingPathComponent("lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: lock.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        let busy = try repo.checkpoint(["snapshot", repo.repo.path, "x"], extraEnvironment: ["ARGOS_CP_LOCK_WAIT": "1"]).stdout
        #expect(busy.contains("ARGOS_CP_FAILED"))
        #expect(FileManager.default.fileExists(atPath: lock.path))
        try "999999\n".write(to: lock.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        try repo.write("a", "y\n")
        let free = try repo.checkpoint(["snapshot", repo.repo.path, "x"], extraEnvironment: ["ARGOS_CP_LOCK_WAIT": "1"]).stdout
        #expect(free.contains("ARGOS_CP_NEW"))
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test("La vista previa avisa antes de hashear lo que el hook rechazó")
    func heavyPreviewAsksFirst() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.sh("dd if=/dev/zero of=enorme.bin bs=1048576 count=25 2>/dev/null")
        let guarded = try repo.checkpoint(["preview", repo.repo.path, point]).stdout
        guard case .heavy(let reason) = try CheckpointParser.parsePreview(guarded, checkpoint: CheckpointScriptTests.sample(point)) else {
            Issue.record("debería avisar"); return
        }
        #expect(reason.contains("20 MB"))
        #expect(throws: CheckpointError.self) {
            try CheckpointParser.parseFiles(try repo.checkpoint(["files", repo.repo.path, point, "-"]).stdout)
        }
    }
}
