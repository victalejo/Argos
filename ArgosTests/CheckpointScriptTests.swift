//
//  CheckpointScriptTests.swift
//  ArgosTests
//
//  El script de los puntos de restauración se EJECUTA de verdad (con /bin/sh y dash)
//  sobre repositorios git temporales: captura, retención, restauración y garantías.
//

import Foundation
import Testing
@testable import Argos

@Suite("CheckpointScript", .serialized)
struct CheckpointScriptTests {

    /// Repo con un commit: `a.txt`, `b.txt`, un `.gitignore` que ignora `.env` y `node_modules/`.
    private func makeRepo(_ shell: String) throws -> CheckpointRepo {
        let repo = try CheckpointRepo(shell: shell)
        try repo.write(".gitignore", ".env\nnode_modules/\n")
        try repo.write("a.txt", "uno\n")
        try repo.write("b.txt", "dos\n")
        try repo.git("add -A && git commit -qm inicial")
        return repo
    }

    private func treeFiles(_ repo: CheckpointRepo, _ ref: String) throws -> [String] {
        try repo.git("ls-tree -r -z --name-only \(ShellQuoting.singleQuoted(ref))").stdout
            .split(separator: "\0").map(String.init).sorted()
    }

    @Test("El hook captura modificados, nuevos y borrados, sin ignorados ni tocar el índice real",
          arguments: CheckpointRepo.shells)
    func captures(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("a.txt", "uno cambiado\n")
        try repo.remove("b.txt")
        try repo.write("nuevo.txt", "nuevo\n")
        try repo.write(".env", "SECRETO=1\n")
        try repo.write("node_modules/x.js", "x\n")
        try repo.git("add a.txt")   // algo preparado en el índice real
        let before = try repo.realState()

        let result = try repo.hook(prompt: "Arregla el \"bug\"\nen la línea 3 ñ")
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)   // nada que Claude tome como contexto
        #expect(try repo.realState() == before)

        let refs = try repo.refs()
        try #require(refs.count == 1)
        #expect(refs[0].hasPrefix("refs/argos/checkpoints/main/"))
        #expect(try treeFiles(repo, refs[0]) == [".gitignore", "a.txt", "nuevo.txt"])
        #expect(try repo.git("show \(refs[0]):a.txt").stdout == "uno cambiado\n")
        let message = try repo.git("log -1 --format=%B \(refs[0])").stdout
        let parsed = CheckpointParser.parseMessage(message)
        #expect(parsed.subject == "Arregla el \"bug\" en la línea 3 ñ")
        #expect(parsed.kind == .prompt)
        #expect(parsed.session == "sesion-1")
        // El padre es HEAD; la rama no se mueve.
        #expect(try repo.git("rev-parse \(refs[0])^").stdout == repo.git("rev-parse HEAD").stdout)
        #expect(try repo.git("rev-list --count HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("Árbol idéntico al anterior: no duplica", arguments: CheckpointRepo.shells)
    func noDuplicates(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.hook()
        try repo.hook(prompt: "otra vez")
        #expect(try repo.refs().count == 1)
        try repo.write("a.txt", "otro\n")
        try repo.hook(prompt: "tercera")
        #expect(try repo.refs().count == 2)
    }

    @Test("Conserva solo los últimos 30 puntos")
    func retention() throws {
        let repo = try makeRepo("/bin/sh")
        for index in 0..<(CheckpointScript.maxCheckpoints + 3) {
            try repo.write("a.txt", "versión \(index)\n")
            let result = try repo.checkpoint(["snapshot", repo.repo.path, "punto \(index)"])
            #expect(result.stdout.contains("ARGOS_CP_NEW"))
        }
        let refs = try repo.refs()
        #expect(refs.count == CheckpointScript.maxCheckpoints)
        // El más reciente sobrevive (los del mismo segundo llevan sufijo ordenable).
        let newest = try repo.git("log -1 --format=%s \(refs[0])").stdout
        #expect(newest.contains("punto \(CheckpointScript.maxCheckpoints + 2)"))
    }

    @Test("No hace nada fuera de un repositorio, con rebase en curso o desactivado",
          arguments: CheckpointRepo.shells)
    func skips(shell: String) throws {
        let repo = try makeRepo(shell)
        let outside = repo.base.appendingPathComponent("suelto", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let result = try repo.hook(cwd: outside)
        #expect(result.exitCode == 0 && result.stdout.isEmpty)
        #expect(try repo.checkpoint(["list", outside.path]).stdout.contains("ARGOS_CP_NOREPO"))

        try FileManager.default.createDirectory(at: repo.repo.appendingPathComponent(".git/rebase-merge"),
                                                withIntermediateDirectories: true)
        try repo.write("a.txt", "cambio\n")
        #expect(try repo.hook().exitCode == 0)
        #expect(try repo.refs().isEmpty)
        #expect(try repo.checkpoint(["preview", repo.repo.path, "HEAD"]).stdout.contains("ARGOS_CP_BUSY rebase-merge"))
        try repo.remove(".git/rebase-merge")

        try repo.git("config argos.checkpoints false")
        try repo.hook()
        #expect(try repo.refs().isEmpty)
        #expect(try repo.checkpoint(["list", repo.repo.path]).stdout.contains("ARGOS_CP_STATE off-repo"))
        try repo.git("config --unset argos.checkpoints")

        #expect(try repo.checkpoint(["server-off"]).stdout.contains("ARGOS_CP_OK"))
        try repo.hook()
        #expect(try repo.refs().isEmpty)
        #expect(try repo.checkpoint(["list", repo.repo.path]).stdout.contains("ARGOS_CP_STATE off-server"))
        try repo.checkpoint(["server-on"])
        try repo.hook()
        #expect(try repo.refs().count == 1)
    }

    @Test("Demasiados archivos nuevos: se rinde y deja el motivo")
    func guardTooMany() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.sh("mkdir gen && i=0; while [ $i -le 1001 ]; do : > gen/f$i; i=$((i+1)); done")
        #expect(try repo.hook().exitCode == 0)
        #expect(try repo.refs().isEmpty)
        let list = try repo.checkpoint(["list", repo.repo.path]).stdout
        #expect(list.contains("ARGOS_CP_SKIPPED "))
        #expect(list.contains("archivos nuevos"))
    }

    @Test("Restaurar entero: recrea, devuelve contenido y borra lo nuevo, nunca lo ignorado",
          arguments: CheckpointRepo.shells)
    func restoreAll(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write(".env", "SECRETO=1\n")
        try repo.hook()
        let point = try #require(try repo.refs().first)

        try repo.write("a.txt", "Claude lo cambió\n")
        try repo.remove("b.txt")
        try repo.write("src/nuevo/modulo.swift", "// nuevo\n")
        try repo.write("node_modules/dep.js", "dep\n")
        try repo.write("src/nuevo/node_modules/ignorado.js", "x\n")
        try repo.write(".env", "SECRETO=2\n")
        let realIndexBefore = try Data(contentsOf: repo.repo.appendingPathComponent(".git/index"))

        let preview = try repo.checkpoint(["preview", repo.repo.path, point]).stdout
        let previewParsed = try CheckpointParser.parsePreview(preview, checkpoint: sample(point))
        #expect(previewParsed.toModify == ["a.txt"])
        #expect(previewParsed.toRecreate == ["b.txt"])
        #expect(previewParsed.toDelete == ["src/nuevo/modulo.swift"])

        let result = try repo.checkpoint(["restore", repo.repo.path, point, previewParsed.currentTree]).stdout
        #expect(result.contains("ARGOS_CP_NEW"))      // copia previa
        #expect(result.contains("ARGOS_CP_DONE"))
        #expect(repo.read("a.txt") == "uno\n")
        #expect(repo.read("b.txt") == "dos\n")
        #expect(!repo.exists("src/nuevo/modulo.swift"))
        #expect(repo.read(".env") == "SECRETO=2\n")
        #expect(repo.read("node_modules/dep.js") == "dep\n")
        #expect(repo.read("src/nuevo/node_modules/ignorado.js") == "x\n")
        #expect(try Data(contentsOf: repo.repo.appendingPathComponent(".git/index")) == realIndexBefore)

        // Deshacer lo deshecho: la copia previa tiene el estado de antes.
        let refs = try repo.refs()
        #expect(refs.count == 2)
        let backup = refs[0]
        #expect(try repo.git("log -1 --format=%s \(backup)").stdout.hasPrefix("Antes de restaurar"))
        let undo = try repo.checkpoint(["restore", repo.repo.path, backup, "-"]).stdout
        #expect(undo.contains("ARGOS_CP_DONE"))
        #expect(repo.read("a.txt") == "Claude lo cambió\n")
        #expect(!repo.exists("b.txt"))
        #expect(repo.read("src/nuevo/modulo.swift") == "// nuevo\n")
    }

    @Test("Si los archivos cambian tras la vista previa, no toca nada")
    func restoreChanged() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.hook()
        let point = try #require(try repo.refs().first)
        try repo.write("a.txt", "cambio 1\n")
        let preview = try CheckpointParser.parsePreview(
            try repo.checkpoint(["preview", repo.repo.path, point]).stdout, checkpoint: sample(point)
        )
        try repo.write("a.txt", "cambio 2\n")
        let result = try repo.checkpoint(["restore", repo.repo.path, point, preview.currentTree]).stdout
        #expect(try CheckpointParser.parseRestore(result) == .changed)
        #expect(repo.read("a.txt") == "cambio 2\n")
    }

    @Test("Restaurar un archivo: lo devuelve o lo borra si no existía", arguments: CheckpointRepo.shells)
    func restoreOneFile(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.hook()
        let point = try #require(try repo.refs().first)
        try repo.write("a.txt", "cambiado\n")
        try repo.write("b.txt", "también\n")
        try repo.write("extra.txt", "nuevo\n")
        #expect(try repo.checkpoint(["restore", repo.repo.path, point, "-", "a.txt"]).stdout.contains("ARGOS_CP_DONE"))
        #expect(repo.read("a.txt") == "uno\n")
        #expect(repo.read("b.txt") == "también\n")
        #expect(try repo.checkpoint(["restore", repo.repo.path, point, "-", "extra.txt"]).stdout.contains("ARGOS_CP_DONE"))
        #expect(!repo.exists("extra.txt"))
        // Un archivo ignorado nunca se borra, aunque se pida.
        try repo.write(".env", "x\n")
        try repo.checkpoint(["restore", repo.repo.path, point, "-", ".env"])
        #expect(repo.exists(".env"))
    }

    @Test("Nombres con espacios, acentos, comillas, comodines y saltos de línea", arguments: CheckpointRepo.shells)
    func trickyNames(shell: String) throws {
        let repo = try makeRepo(shell)
        let names = ["con espacio.txt", "acentuado ñandú.md", "comilla'simple\".txt", "*", "salto\nlinea.txt", "-guion.txt"]
        for name in names { try repo.write("raros/\(name)", "v1 \(name)\n") }
        try repo.hook()
        let point = try #require(try repo.refs().first)
        #expect(try treeFiles(repo, point).filter { $0.hasPrefix("raros/") }.count == names.count)

        for name in names { try repo.write("raros/\(name)", "v2\n") }
        let files = try CheckpointParser.parseFiles(try repo.checkpoint(["files", repo.repo.path, point, "-"]).stdout)
        #expect(Set(files.map(\.path)) == Set(names.map { "raros/\($0)" }))
        #expect(files.allSatisfy { $0.kind == .modified })

        let diff = try repo.checkpoint(["diff", repo.repo.path, point, "-", "raros/*", "100000"]).stdout
        let parsed = GitDiffParser.parse(diff)
        #expect(parsed.additions == 1 && parsed.deletions == 1)   // solo el archivo «*», no todos

        let one = "raros/comilla'simple\".txt"
        #expect(try repo.checkpoint(["restore", repo.repo.path, point, "-", one]).stdout.contains("ARGOS_CP_DONE"))
        #expect(repo.read(one) == "v1 comilla'simple\".txt\n")
        #expect(repo.read("raros/*") == "v2\n")
    }

    @Test("Las refs de los puntos no viajan con git push ni con clone")
    func notPushed() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.write("a.txt", "cambio\n")
        try repo.hook()
        #expect(try repo.refs().count == 1)
        let remote = repo.base.appendingPathComponent("remoto.git").path
        try repo.git("init -q --bare \(ShellQuoting.singleQuoted(remote))")
        try repo.git("remote add origin \(ShellQuoting.singleQuoted(remote))")
        try repo.git("push -q origin HEAD && git push -q --all origin && git push -q --tags origin")
        let remoteRefs = try repo.sh("git --git-dir=\(ShellQuoting.singleQuoted(remote)) for-each-ref --format='%(refname)'").stdout
        #expect(!remoteRefs.contains("refs/argos"))
    }

    @Test("Un worktree enlazado tiene sus propios puntos")
    func linkedWorktree() throws {
        let repo = try makeRepo("/bin/sh")
        let other = repo.base.appendingPathComponent("otra rama")
        try repo.git("worktree add -q -b otra \(ShellQuoting.singleQuoted(other.path))")
        try "cambio\n".write(to: other.appendingPathComponent("a.txt"), atomically: false, encoding: .utf8)
        try repo.hook(cwd: other)
        let refs = try repo.refs()
        #expect(refs.count == 1)
        #expect(refs[0].hasPrefix("refs/argos/checkpoints/w-"))
        let output = try repo.checkpoint(["list", repo.repo.path]).stdout
        guard case .listing(let listing) = try CheckpointParser.parseList(output) else {
            Issue.record("sin lista: \(output)"); return
        }
        #expect(listing.checkpoints.isEmpty, "el repo principal no ve los puntos del otro worktree")
        // Foundation muestra /private/var como /var: se comparan ya resueltas.
        #expect(URL(fileURLWithPath: listing.root).resolvingSymlinksInPath().path
            == repo.repo.resolvingSymlinksInPath().path)
        let otherOutput = try repo.checkpoint(["list", other.path]).stdout
        guard case .listing(let otherListing) = try CheckpointParser.parseList(otherOutput) else {
            Issue.record("sin lista: \(otherOutput)"); return
        }
        #expect(otherListing.checkpoints.count == 1)
    }

    @Test("Repo sin commits: captura sin padre")
    func unbornBranch() throws {
        let repo = try CheckpointRepo()
        try repo.write("primero.txt", "hola\n")
        try repo.hook()
        let point = try #require(try repo.refs().first)
        #expect(try repo.git("rev-list --parents -n 1 \(point)").stdout.split(separator: " ").count == 1)
        let listing = try CheckpointParser.parseList(try repo.checkpoint(["list", repo.repo.path]).stdout)
        guard case .listing(let value) = listing else { Issue.record("sin lista"); return }
        #expect(value.headCommit == nil)
        #expect(value.checkpoints.first?.parent == nil)
    }

    @Test("El comando del hook tal cual se instala: siempre 0 y sin salida, con o sin script")
    func installedHookCommand() throws {
        let repo = try makeRepo("/bin/sh")
        try repo.write("a.txt", "cambio\n")
        let input = #"{"session_id":"s","prompt":"hola","hook_event_name":"UserPromptSubmit"}"#
        let missing = try repo.exec("/bin/sh", ["-c", ClaudeHookInstaller.checkpointCommand], stdin: input)
        #expect(missing.exitCode == 0 && missing.stdout.isEmpty && missing.stderr.isEmpty)
        try repo.installScript()
        let run = try repo.exec("/bin/sh", ["-c", ClaudeHookInstaller.checkpointCommand], stdin: input)
        #expect(run.exitCode == 0 && run.stdout.isEmpty && run.stderr.isEmpty)
        #expect(try repo.refs().count == 1)
    }

    // MARK: - Utilidades

    private func headCommit(_ repo: CheckpointRepo) throws -> String {
        try repo.git("rev-parse HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sample(_ ref: String) -> Checkpoint {
        Checkpoint(ref: ref, commit: ref, parent: nil, date: Date(), kind: .prompt,
                   sessionID: nil, label: "", changedFiles: nil)
    }
}
