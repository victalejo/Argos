//
//  CheckpointScriptTests.swift
//  ArgosTests
//
//  El script de los puntos de restauración se EJECUTA de verdad (con /bin/sh y dash)
//  sobre repositorios git temporales: captura, alcance, retención, almacenamiento aparte y
//  restauración normal. Los casos de pérdida de datos están en `CheckpointSafetyTests`.
//

import Foundation
import Testing
@testable import Argos

@Suite("CheckpointScript", .serialized)
struct CheckpointScriptTests {

    /// Repo con un commit: `a.txt`, `b.txt` y un `.gitignore` que ignora `.env` y `node_modules/`.
    static func makeRepo(_ shell: String, enabled: Bool = true) throws -> CheckpointRepo {
        let repo = try CheckpointRepo(shell: shell, enabled: enabled)
        try repo.write(".gitignore", ".env\nnode_modules/\n")
        try repo.write("a.txt", "uno\n")
        try repo.write("b.txt", "dos\n")
        try repo.git("add -A && git commit -qm inicial")
        return repo
    }

    @Test("El hook captura modificados, nuevos y borrados, sin ignorados ni tocar el índice real",
          arguments: CheckpointRepo.shells)
    func captures(shell: String) throws {
        let repo = try Self.makeRepo(shell)
        try repo.write("a.txt", "uno cambiado\n")
        try repo.remove("b.txt")
        try repo.write("nuevo.txt", "nuevo\n")
        try repo.write(".env", "SECRETO=1\n")
        try repo.write("node_modules/x.js", "x\n")
        try repo.git("add a.txt")
        let before = try repo.realState()

        let result = try repo.hook(prompt: "Arregla el \"bug\"\nen la línea 3 ñ")
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(try repo.realState() == before)

        let points = try repo.points()
        try #require(points.count == 1)
        #expect(try repo.files(of: points[0]) == [".gitignore", "a.txt", "nuevo.txt"])
        #expect(try repo.show(points[0], "a.txt") == "uno cambiado\n")
        let message = CheckpointParser.parseMessage(try repo.storeGit("log -1 --format=%B \(points[0])").stdout)
        #expect(message.subject == "Turno 1", "sin activar los extractos no se guarda el mensaje")
        #expect(message.kind == .prompt)
        #expect(message.session == "sesion-1")
        #expect(try repo.storeGit("rev-parse \(points[0])^").stdout == repo.git("rev-parse HEAD").stdout)
        #expect(try repo.git("rev-list --count HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("Con los extractos activados, el punto lleva una línea del mensaje")
    func storesPromptWhenEnabled() throws {
        let repo = try Self.makeRepo("/bin/sh")
        try repo.checkpoint(["prompts", repo.repo.path, "true"])
        try repo.write("a.txt", "x\n")
        try repo.hook(prompt: "Arregla el \"bug\"\nen la línea 3 ñ")
        let point = try #require(try repo.points().first)
        let message = CheckpointParser.parseMessage(try repo.storeGit("log -1 --format=%B \(point)").stdout)
        #expect(message.subject == "Arregla el \"bug\" en la línea 3 ñ")
    }

    @Test("Sin argos.checkpoints=true el hook no hace nada ni crea nada", arguments: CheckpointRepo.shells)
    func requiresOptIn(shell: String) throws {
        let repo = try Self.makeRepo(shell, enabled: false)
        try repo.write("a.txt", "cambio\n")
        let result = try repo.hook()
        #expect(result.exitCode == 0 && result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.store.path))
        try repo.git("config argos.checkpoints false")
        try repo.hook()
        #expect(!FileManager.default.fileExists(atPath: repo.store.path))
        let list = try CheckpointParser.parseList(try repo.checkpoint(["list", repo.repo.path]).stdout)
        guard case .listing(let listing) = list else { Issue.record("sin lista"); return }
        #expect(!listing.isEnabled && listing.checkpoints.isEmpty)
    }

    @Test("Árbol idéntico al anterior: no duplica", arguments: CheckpointRepo.shells)
    func noDuplicates(shell: String) throws {
        let repo = try Self.makeRepo(shell)
        try repo.hook()
        try repo.hook(prompt: "otra vez")
        #expect(try repo.points().count == 1)
        try repo.write("a.txt", "otro\n")
        try repo.hook(prompt: "tercera")
        #expect(try repo.points().count == 2)
    }

    @Test("Conserva solo los últimos 30 puntos, también los «Antes de restaurar»")
    func retention() throws {
        let repo = try Self.makeRepo("/bin/sh")
        for index in 0..<(CheckpointScript.maxCheckpoints + 3) {
            try repo.write("a.txt", "versión \(index)\n")
            #expect(try repo.checkpoint(["snapshot", repo.repo.path, "punto \(index)"]).stdout.contains("ARGOS_CP_NEW"))
        }
        let points = try repo.points()
        #expect(points.count == CheckpointScript.maxCheckpoints)
        #expect(try repo.storeGit("log -1 --format=%s \(points[0])").stdout.contains("punto \(CheckpointScript.maxCheckpoints + 2)"))
        try repo.write("a.txt", "otra\n")
        try repo.restore(points[5])
        #expect(try repo.points().count == CheckpointScript.maxCheckpoints)
    }

    @Test("No hace nada fuera de un repositorio ni con un rebase en curso", arguments: CheckpointRepo.shells)
    func skips(shell: String) throws {
        let repo = try Self.makeRepo(shell)
        let outside = repo.base.appendingPathComponent("suelto", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let result = try repo.hook(cwd: outside)
        #expect(result.exitCode == 0 && result.stdout.isEmpty)
        #expect(try repo.checkpoint(["list", outside.path]).stdout.contains("ARGOS_CP_NOREPO"))

        try FileManager.default.createDirectory(at: repo.repo.appendingPathComponent(".git/rebase-merge"),
                                                withIntermediateDirectories: true)
        try repo.write("a.txt", "cambio\n")
        #expect(try repo.hook().exitCode == 0)
        #expect(try repo.points().isEmpty)
        #expect(try repo.checkpoint(["preview", repo.repo.path, "HEAD"]).stdout.contains("ARGOS_CP_BUSY rebase-merge"))
    }

    @Test("Demasiados archivos nuevos: se rinde y deja el motivo")
    func guardTooMany() throws {
        let repo = try Self.makeRepo("/bin/sh")
        try repo.hook()
        try repo.sh("mkdir gen && i=0; while [ $i -le 1001 ]; do : > gen/f$i; i=$((i+1)); done")
        #expect(try repo.hook().exitCode == 0)
        #expect(try repo.points().count == 1)
        let output = try repo.checkpoint(["list", repo.repo.path]).stdout
        guard case .listing(let listing) = try CheckpointParser.parseList(output) else { Issue.record("sin lista"); return }
        #expect(listing.skips.last?.reason.contains("archivos nuevos") == true)
        #expect(listing.skips(duringTurnAt: 0).count == 1)
    }

    @Test("Restaurar entero: recrea, devuelve contenido y borra lo nuevo, nunca lo ignorado",
          arguments: CheckpointRepo.shells)
    func restoreAll(shell: String) throws {
        let repo = try Self.makeRepo(shell)
        try repo.write(".env", "SECRETO=1\n")
        try repo.hook()
        let point = try #require(try repo.points().first)

        try repo.write("a.txt", "Claude lo cambió\n")
        try repo.remove("b.txt")
        try repo.write("src/nuevo/modulo.swift", "// nuevo\n")
        try repo.write("node_modules/dep.js", "dep\n")
        try repo.write("src/nuevo/node_modules/ignorado.js", "x\n")
        try repo.write(".env", "SECRETO=2\n")
        let realIndexBefore = try Data(contentsOf: repo.repo.appendingPathComponent(".git/index"))

        let previewText = try repo.checkpoint(["preview", repo.repo.path, point, "full"]).stdout
        guard case .ready(let preview) = try CheckpointParser.parsePreview(previewText, checkpoint: Self.sample(point)) else {
            Issue.record("sin vista previa"); return
        }
        #expect(preview.toModify == ["a.txt"])
        #expect(preview.toRecreate == ["b.txt"])
        #expect(preview.toDelete == ["src/nuevo/modulo.swift"])
        #expect(preview.issues.isEmpty)

        let result = try repo.checkpoint(["restore", repo.repo.path, point, preview.currentTree]).stdout
        #expect(result.contains("ARGOS_CP_NEW"))
        #expect(result.contains("ARGOS_CP_DONE"))
        #expect(repo.read("a.txt") == "uno\n")
        #expect(repo.read("b.txt") == "dos\n")
        #expect(!repo.exists("src/nuevo/modulo.swift"))
        #expect(repo.read(".env") == "SECRETO=2\n")
        #expect(repo.read("node_modules/dep.js") == "dep\n")
        #expect(repo.read("src/nuevo/node_modules/ignorado.js") == "x\n")
        #expect(try Data(contentsOf: repo.repo.appendingPathComponent(".git/index")) == realIndexBefore)

        let points = try repo.points()
        #expect(points.count == 2)
        #expect(try repo.storeGit("log -1 --format=%s \(points[0])").stdout.hasPrefix("Antes de restaurar"))
        #expect(try repo.checkpoint(["restore", repo.repo.path, points[0], "-"]).stdout.contains("ARGOS_CP_DONE"))
        #expect(repo.read("a.txt") == "Claude lo cambió\n")
        #expect(!repo.exists("b.txt"))
        #expect(repo.read("src/nuevo/modulo.swift") == "// nuevo\n")
    }

    @Test("Si los archivos cambian tras la vista previa, no toca nada")
    func restoreChanged() throws {
        let repo = try Self.makeRepo("/bin/sh")
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.write("a.txt", "cambio 1\n")
        let previewText = try repo.checkpoint(["preview", repo.repo.path, point, "full"]).stdout
        guard case .ready(let preview) = try CheckpointParser.parsePreview(previewText, checkpoint: Self.sample(point)) else {
            Issue.record("sin vista previa"); return
        }
        try repo.write("a.txt", "cambio 2\n")
        let result = try repo.checkpoint(["restore", repo.repo.path, point, preview.currentTree]).stdout
        #expect(try CheckpointParser.parseRestore(result) == .changed)
        #expect(repo.read("a.txt") == "cambio 2\n")
    }

    @Test("Restaurar un archivo: lo devuelve o lo borra si no existía", arguments: CheckpointRepo.shells)
    func restoreOneFile(shell: String) throws {
        let repo = try Self.makeRepo(shell)
        try repo.hook()
        let point = try #require(try repo.points().first)
        try repo.write("a.txt", "cambiado\n")
        try repo.write("b.txt", "también\n")
        try repo.write("extra.txt", "nuevo\n")
        #expect(try repo.checkpoint(["restore", repo.repo.path, point, "-", "a.txt"]).stdout.contains("ARGOS_CP_DONE"))
        #expect(repo.read("a.txt") == "uno\n")
        #expect(repo.read("b.txt") == "también\n")
        #expect(try repo.checkpoint(["restore", repo.repo.path, point, "-", "extra.txt"]).stdout.contains("ARGOS_CP_DONE"))
        #expect(!repo.exists("extra.txt"))
        try repo.write(".env", "x\n")
        let ignored = try repo.checkpoint(["restore", repo.repo.path, point, "-", ".env"]).stdout
        #expect(ignored.contains("ARGOS_CP_NOOP"))
        #expect(repo.exists(".env"))
    }

    @Test("Nombres con espacios, acentos, comillas, comodines, guiones y saltos de línea",
          arguments: CheckpointRepo.shells)
    func trickyNames(shell: String) throws {
        let repo = try Self.makeRepo(shell)
        let names = ["con espacio.txt", "acentuado ñandú.md", "comilla'simple\".txt", "*", "salto\nlinea.txt", "-rf"]
        for name in names { try repo.write("raros/\(name)", "v1 \(name)\n") }
        try repo.hook()
        let point = try #require(try repo.points().first)
        #expect(try repo.files(of: point).filter { $0.hasPrefix("raros/") }.count == names.count)

        for name in names { try repo.write("raros/\(name)", "v2\n") }
        try repo.write("nuevo", "n\n")
        let files = try CheckpointParser.parseFiles(try repo.checkpoint(["files", repo.repo.path, point, "-"]).stdout)
        #expect(Set(files.map(\.path)) == Set(names.map { "raros/\($0)" } + ["nuevo"]))

        let diff = try repo.checkpoint(["diff", repo.repo.path, point, "-", "raros/*", "100000"]).stdout
        let parsed = GitDiffParser.parse(diff)
        #expect(parsed.additions == 1 && parsed.deletions == 1)

        let one = "raros/comilla'simple\".txt"
        #expect(try repo.checkpoint(["restore", repo.repo.path, point, "-", one]).stdout.contains("ARGOS_CP_DONE"))
        #expect(repo.read(one) == "v1 comilla'simple\".txt\n")
        #expect(repo.read("raros/*") == "v2\n")

        #expect(try repo.restore(point).contains("ARGOS_CP_DONE"))
        for name in names { #expect(repo.read("raros/\(name)") == "v1 \(name)\n") }
        #expect(!repo.exists("nuevo"))
    }

    @Test("Los puntos no están en refs/, ni en log --all, ni en push --mirror, ni en un clon --mirror")
    func neverLeaveTheRepository() throws {
        let repo = try Self.makeRepo("/bin/sh")
        try repo.write("secretos.txt", "TOKEN=abc\n")
        try repo.checkpoint(["prompts", repo.repo.path, "true"])
        try repo.hook(prompt: "mi clave es abc")
        #expect(try repo.points().count == 1)
        #expect(try repo.git("for-each-ref").stdout.split(separator: "\n").count == 1)   // solo la rama
        #expect(!(try repo.git("log --all --format=%s").stdout.contains("clave")))
        let remote = repo.base.appendingPathComponent("remoto.git").path
        try repo.git("init -q --bare \(ShellQuoting.singleQuoted(remote))")
        try repo.git("push -q --mirror \(ShellQuoting.singleQuoted(remote))")
        let remoteRefs = try repo.sh("git --git-dir=\(ShellQuoting.singleQuoted(remote)) for-each-ref --format='%(refname)'").stdout
        #expect(!remoteRefs.contains("checkpoint"))
        let remoteCommits = try repo.sh("git --git-dir=\(ShellQuoting.singleQuoted(remote)) rev-list --all --count").stdout
        #expect(remoteCommits.trimmingCharacters(in: .whitespacesAndNewlines) == "1")

        let mirror = repo.base.appendingPathComponent("espejo.git").path
        try repo.sh("git clone -q --mirror . \(ShellQuoting.singleQuoted(mirror))")
        let mirrorRefs = try repo.sh("git --git-dir=\(ShellQuoting.singleQuoted(mirror)) for-each-ref --format='%(refname)'").stdout
        #expect(!mirrorRefs.contains("checkpoint"))
        #expect(!FileManager.default.fileExists(atPath: mirror + "/" + CheckpointScript.storeName))
        // gc del principal no los alcanza.
        try repo.git("gc -q --prune=now")
        #expect(try repo.points().count == 1)
    }

    @Test("Un worktree enlazado tiene sus puntos y uno nuevo con el mismo nombre no los hereda")
    func linkedWorktree() throws {
        let repo = try Self.makeRepo("/bin/sh")
        let other = repo.base.appendingPathComponent("otra rama")
        let quoted = ShellQuoting.singleQuoted(other.path)
        try repo.git("worktree add -q -b otra \(quoted)")
        try "cambio\n".write(to: other.appendingPathComponent("a.txt"), atomically: false, encoding: .utf8)
        try repo.hook(cwd: other)
        let gitDir = try repo.sh("git -C \(quoted) rev-parse --absolute-git-dir").stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(gitDir.contains("/.git/worktrees/"))
        let otherStore = URL(fileURLWithPath: gitDir).appendingPathComponent(CheckpointScript.storeName)
        #expect(try repo.points(store: otherStore).count == 1)
        #expect(try repo.points().isEmpty)

        let output = try repo.checkpoint(["list", repo.repo.path]).stdout
        guard case .listing(let listing) = try CheckpointParser.parseList(output) else { Issue.record("sin lista: \(output)"); return }
        #expect(listing.checkpoints.isEmpty)

        try repo.git("worktree remove --force \(quoted)")
        try repo.git("worktree add -q -b otra2 \(quoted)")
        let reused = try repo.checkpoint(["list", other.path]).stdout
        guard case .listing(let fresh) = try CheckpointParser.parseList(reused) else { Issue.record("sin lista"); return }
        #expect(fresh.checkpoints.isEmpty)
    }

    @Test("Repo sin commits: captura sin padre")
    func unbornBranch() throws {
        let repo = try CheckpointRepo()
        try repo.write("primero.txt", "hola\n")
        try repo.hook()
        let point = try #require(try repo.points().first)
        #expect(try repo.storeGit("rev-list --parents -n 1 \(point)").stdout.split(separator: " ").count == 1)
        guard case .listing(let value) = try CheckpointParser.parseList(try repo.checkpoint(["list", repo.repo.path]).stdout) else {
            Issue.record("sin lista"); return
        }
        #expect(value.headCommit == nil)
        #expect(value.checkpoints.first?.parent == nil)
    }

    @Test("El comando del hook tal cual se instala: siempre 0 y sin salida, con o sin script")
    func installedHookCommand() throws {
        let repo = try Self.makeRepo("/bin/sh")
        try repo.write("a.txt", "cambio\n")
        let input = #"{"session_id":"s","prompt":"hola","hook_event_name":"UserPromptSubmit"}"#
        let missing = try repo.exec("/bin/sh", ["-c", CheckpointHookInstaller.command], stdin: input)
        #expect(missing.exitCode == 0 && missing.stdout.isEmpty && missing.stderr.isEmpty)
        try repo.installScript()
        let run = try repo.exec("/bin/sh", ["-c", CheckpointHookInstaller.command], stdin: input)
        #expect(run.exitCode == 0 && run.stdout.isEmpty && run.stderr.isEmpty)
        #expect(try repo.points().count == 1)
    }

    @Test("Desactivar y «Borrar todos» retiran los puntos y los índices privados")
    func purgeAndDisable() throws {
        let repo = try Self.makeRepo("/bin/sh")
        try repo.write("a.txt", "x\n")
        try repo.hook()
        #expect(FileManager.default.fileExists(atPath: repo.store.path))
        #expect(try repo.checkpoint(["purge", repo.repo.path]).stdout.contains("ARGOS_CP_OK"))
        #expect(!FileManager.default.fileExists(atPath: repo.store.path))
        try repo.write("a.txt", "y\n")
        try repo.hook()
        #expect(try repo.points().count == 1)
        #expect(try repo.checkpoint(["disable", repo.repo.path]).stdout.contains("ARGOS_CP_OK"))
        #expect(!FileManager.default.fileExists(atPath: repo.store.path))
        let leftovers = try repo.sh("ls .git | grep -i argos || true").stdout
        #expect(leftovers.isEmpty)
        try repo.write("a.txt", "z\n")
        try repo.hook()
        #expect(!FileManager.default.fileExists(atPath: repo.store.path))
    }

    static func sample(_ commit: String) -> Checkpoint {
        Checkpoint(ref: commit, commit: commit, parent: nil, date: Date(), kind: .prompt,
                   sessionID: nil, label: "", changedFiles: nil)
    }
}
