//
//  CheckpointHardeningTests.swift
//  ArgosTests
//
//  Segunda revisión de seguridad (t1…t17 de la tercera ronda) como tests que ejecutan el
//  script real con /bin/sh y dash: marcas del índice, «racy git», puntos dañados por `gc`,
//  cambios durante la restauración, límites del hook con nombres hostiles y repos grandes,
//  entorno de git heredado, repos incrustados, rutas vacías, LFS y restos de `kill -9`.
//

import Foundation
import Testing
@testable import Argos

@Suite("Checkpoint · endurecimiento", .serialized)
struct CheckpointHardeningTests {

    private func makeRepo(_ shell: String = "/bin/sh") throws -> CheckpointRepo {
        let repo = try CheckpointRepo(shell: shell)
        try repo.write("a.txt", "base\n")
        try repo.git("add -A && git commit -qm init")
        return repo
    }

    private func snapshot(_ repo: CheckpointRepo, environment: [String: String] = [:]) throws -> String {
        let output = try repo.checkpoint(["snapshot", repo.repo.path, "x"], extraEnvironment: environment).stdout
        let line = try #require(output.components(separatedBy: "\n").first {
            $0.hasPrefix("ARGOS_CP_NEW ") || $0.hasPrefix("ARGOS_CP_SAME ")
        })
        return String(line.split(separator: " ")[1])
    }

    @Test("skip-worktree: la copia previa guarda lo del disco antes de restaurar (todo y un archivo)",
          arguments: CheckpointRepo.shells)
    func skipWorktree(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("s.txt", "orig\n")
        try repo.git("add -A && git commit -qm s")
        let point = try snapshot(repo)
        try repo.write("s.txt", "cambio1\n")
        try repo.git("commit -qam c2 && git update-index --skip-worktree s.txt")
        try repo.write("s.txt", "VALIOSO\n")
        let flags = try repo.git("ls-files -v").stdout
        let restored = try repo.restore(point)
        let latestTree = try repo.storeGit("ls-tree -r \(try repo.points().first ?? "")").stdout
        #expect(try repo.inLatest("s.txt") == "VALIOSO\n", "flags: \(flags) restore: \(restored) tree: \(latestTree)")
        #expect(repo.read("s.txt") == "orig\n")

        try repo.write("s.txt", "VALIOSO2\n")
        let one = try repo.checkpoint(["restore", repo.repo.path, point, "-", "s.txt"]).stdout
        #expect(one.contains("ARGOS_CP_DONE"))
        #expect(try repo.inLatest("s.txt") == "VALIOSO2\n")
    }

    @Test("assume-unchanged: igual (todo y un archivo)", arguments: CheckpointRepo.shells)
    func assumeUnchanged(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("conf.txt", "orig\n")
        try repo.git("add -A && git commit -qm c")
        let point = try snapshot(repo)
        try repo.write("conf.txt", "turno1\n")
        try repo.git("commit -qam t1 && git update-index --assume-unchanged conf.txt")
        try repo.write("conf.txt", "VALIOSO\n")
        try repo.restore(point)
        #expect(try repo.inLatest("conf.txt") == "VALIOSO\n")
        try repo.write("conf.txt", "VALIOSO2\n")
        try repo.checkpoint(["restore", repo.repo.path, point, "-", "conf.txt"])
        #expect(try repo.inLatest("conf.txt") == "VALIOSO2\n")
    }

    @Test("racy git (t9): un cambio del mismo segundo y tamaño llega a la copia previa", arguments: CheckpointRepo.shells)
    func racyGit(shell: String) throws {
        for _ in 0..<4 {
            let repo = try CheckpointRepo(shell: shell)
            try repo.write("r", "v0\n")
            try repo.git("add -A && git commit -qm i0")
            let point = try snapshot(repo)
            try repo.sh("echo v1 > r && git commit -qam i1 && echo v2 > r")
            usleep(1_200_000)
            let result = try repo.restore(point)
            #expect(try repo.inLatest("r") == "v2\n", "copia previa: \(result)")
        }
    }

    @Test("Un punto sellado sobrevive a gc --prune=now del principal")
    func sealedSurvivesGC() throws {
        let repo = try makeRepo()
        try repo.write("b.txt", "base\n")
        try repo.git("add -A && git commit -qm b")
        try repo.write("a.txt", "STAGED-ONLY\n")
        try repo.git("add a.txt")
        let point = try snapshot(repo)
        try repo.git("reset -q --hard && git gc -q --prune=now")
        try repo.write("b.txt", "otro\n")
        let list = try repo.checkpoint(["list", repo.repo.path]).stdout
        #expect(!list.contains("ARGOS_CP_DAMAGED"))
        #expect(try repo.checkpoint(["restore", repo.repo.path, point, "-", "a.txt"]).stdout.contains("ARGOS_CP_DONE"))
        #expect(repo.read("a.txt") == "STAGED-ONLY\n")
    }

    @Test("Un punto sin sellar y dañado por gc: se marca y nunca borra ni «restaura» nada", arguments: CheckpointRepo.shells)
    func damagedPoint(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("a.txt", "STAGED-ONLY\n")
        try repo.git("add a.txt")
        let point = try snapshot(repo, environment: ["ARGOS_CP_TEST_NO_SEAL": "1"])
        try repo.git("reset -q --hard && git gc -q --prune=now")
        try repo.write("b.txt", "nuevo\n")

        #expect(try repo.checkpoint(["list", repo.repo.path]).stdout.contains("ARGOS_CP_DAMAGED \(point)"))
        let preview = try repo.checkpoint(["preview", repo.repo.path, point, "full"]).stdout
        #expect(throws: CheckpointError.damaged) {
            try CheckpointParser.parsePreview(preview, checkpoint: CheckpointScriptTests.sample(point))
        }
        let full = try repo.checkpoint(["restore", repo.repo.path, point, "-"]).stdout
        #expect(throws: CheckpointError.damaged) { try CheckpointParser.parseRestore(full) }
        let one = try repo.checkpoint(["restore", repo.repo.path, point, "-", "a.txt"]).stdout
        #expect(throws: CheckpointError.damaged) { try CheckpointParser.parseRestore(one) }
        #expect(repo.read("a.txt") == "base\n")
        #expect(repo.read("b.txt") == "nuevo\n")
    }

    @Test("Un archivo que cambia entre la copia previa y la escritura no se toca", arguments: CheckpointRepo.shells)
    func changeDuringRestore(shell: String) throws {
        let repo = try makeRepo(shell)
        try repo.write("b.txt", "b1\n")
        let point = try snapshot(repo)
        try repo.write("a.txt", "a2\n")
        try repo.write("b.txt", "b2\n")
        let result = try repo.restore(point, extraEnvironment: ["ARGOS_CP_TEST_BEFORE_WRITE": "echo CLAUDE > a.txt"])
        let outcome = try CheckpointParser.parseRestore(result)
        #expect(outcome == .partial(backup: try repo.points().first, skipped: [CheckpointIssue(kind: .changedOnDisk, path: "a.txt")]))
        #expect(repo.read("a.txt") == "CLAUDE\n")
        #expect(repo.read("b.txt") == "b1\n")
    }

    @Test("El límite de tamaño vale para nombres con comillas, barras, tabuladores y saltos de línea",
          arguments: ["dump\"2.bin", "back\\slash.bin", "tab\there.bin", "new\nline.bin"])
    func sizeLimitWithHostileNames(name: String) throws {
        let repo = try makeRepo()
        try repo.hook()
        let before = try repo.points().count
        let file = repo.repo.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: Data(count: 25 * 1_048_576))
        try repo.hook(prompt: "grande")
        #expect(try repo.points().count == before)
        let size = try repo.sh("du -sk .git/\(CheckpointScript.storeName) | cut -f1").stdout
        #expect((Int(size.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) < 5_000)
    }

    @Test("Hook con 20.000 archivos y 1.900 modificados: dentro del plazo global")
    func manyFiles() throws {
        let repo = try makeRepo()
        try repo.sh("i=0; while [ $i -lt 200 ]; do mkdir -p src/d$i; j=0; while [ $j -lt 100 ]; do echo \"$i $j\" > src/d$i/f$j; j=$((j+1)); done; i=$((i+1)); done")
        try repo.git("add -A && git commit -qm big")
        let first = try repo.timedHook()
        try repo.sh("i=0; while [ $i -lt 1900 ]; do echo mod >> src/d$((i/100))/f$((i%100)); i=$((i+1)); done")
        let second = try repo.timedHook(prompt: "muchos")
        #expect(first < 8 && second < 8, "hook: \(first) s y \(second) s")
    }

    @Test("GIT_DIR y GIT_WORK_TREE heredados no desvían el punto a otro repositorio")
    func inheritedGitEnvironment() throws {
        let repo = try makeRepo()
        let other = repo.base.appendingPathComponent("otro")
        try repo.sh("git init -q \(ShellQuoting.singleQuoted(other.path)) && cd \(ShellQuoting.singleQuoted(other.path)) && git config user.email t@t && git config user.name t && echo o > o && git add -A && git commit -qm o")
        try repo.write("a.txt", "cambio\n")
        try repo.hook(extraEnvironment: ["GIT_DIR": other.path + "/.git", "GIT_WORK_TREE": other.path,
                                        "GIT_INDEX_FILE": other.path + "/.git/index"])
        #expect(try repo.points().count == 1)
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent(".git/\(CheckpointScript.storeName)").path))
    }

    @Test("Carpeta vacía, repositorio bare incrustado y worktree con enlace roto: no se tocan",
          arguments: CheckpointRepo.shells)
    func embeddedRepositories(shell: String) throws {
        let repo = try makeRepo(shell)
        let point = try snapshot(repo)
        try FileManager.default.createDirectory(at: repo.repo.appendingPathComponent("vacia"), withIntermediateDirectories: true)
        try repo.write("wtbroken/.git", "gitdir: /no/existe/.git/worktrees/x\n")
        try repo.write("wtbroken/w", "TRABAJO\n")
        try repo.sh("mkdir -p barerepo && git init -q --bare barerepo/inner.git && echo cfg > barerepo/notes")
        let result = try repo.restore(point)
        guard case .conflict(let issues) = try CheckpointParser.parseRestore(result) else {
            Issue.record("debería negarse: \(result)"); return
        }
        #expect(issues.contains { $0.kind == .nestedRepository && $0.path == "wtbroken/w" })
        #expect(issues.contains { $0.kind == .nestedRepository && $0.path.hasPrefix("barerepo/inner.git/") })
        #expect(repo.read("wtbroken/w") == "TRABAJO\n")
        #expect(repo.exists("barerepo/inner.git/HEAD") && repo.exists("barerepo/inner.git/objects"))
        #expect(repo.exists("vacia"))
    }

    @Test("Una ruta vacía no restaura todo", arguments: CheckpointRepo.shells)
    func emptyPath(shell: String) throws {
        let repo = try makeRepo(shell)
        let point = try snapshot(repo)
        try repo.write("a.txt", "cambio\n")
        let result = try repo.checkpoint(["restore", repo.repo.path, point, "-", ""]).stdout
        #expect(try CheckpointParser.parseRestore(result) == .nothing(CheckpointParser.noopText("invalid")))
        #expect(repo.read("a.txt") == "cambio\n")
    }

    @Test("Un archivo sin seguimiento con permisos 0600 no se borra (la copia no guarda permisos)")
    func restrictedPermissions() throws {
        let repo = try makeRepo()
        let point = try snapshot(repo)
        try repo.write("clave.pem", "SECRETA\n")
        try repo.sh("chmod 600 clave.pem")
        let result = try repo.restore(point)
        #expect(try CheckpointParser.parseRestore(result) == .conflict([CheckpointIssue(kind: .permissions, path: "clave.pem")]))
        #expect(repo.read("clave.pem") == "SECRETA\n")
    }

    @Test("Con Git LFS no se captura (ni se escribe en .git/lfs) y se dice por qué")
    func gitLFS() throws {
        let repo = try makeRepo()
        try repo.git("config filter.lfs.process 'git-lfs filter-process' && git config filter.lfs.required true")
        try repo.write(".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n")
        try repo.write("a.txt", "cambio\n")
        try repo.hook()
        #expect(try repo.points().isEmpty)
        #expect(!repo.exists(".git/lfs"))
        let list = try repo.checkpoint(["list", repo.repo.path]).stdout
        guard case .listing(let listing) = try CheckpointParser.parseList(list) else { Issue.record("sin lista"); return }
        #expect(listing.usesLFS)
        #expect(listing.skips.last?.reason.contains("LFS") == true)
    }

    @Test("Un fallo de git add guarda el motivo de git; restos de procesos muertos se limpian")
    func addFailureAndLeftovers() throws {
        let repo = try makeRepo()
        try repo.hook()
        try repo.write("secreto", "x\n")
        try repo.sh("chmod 000 secreto")
        defer { _ = try? repo.sh("chmod 644 secreto") }
        try repo.hook(prompt: "otro")
        let list = try repo.checkpoint(["list", repo.repo.path]).stdout
        guard case .listing(let listing) = try CheckpointParser.parseList(list) else { Issue.record("sin lista"); return }
        #expect(listing.skips.last?.reason.hasPrefix("git add:") == true)
        try repo.sh("chmod 644 secreto")

        let leftover = repo.store.appendingPathComponent("tmp.999999")
        try "x".write(to: leftover, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.store.appendingPathComponent("scratch.999998"), withIntermediateDirectories: true)
        _ = try snapshot(repo)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(!FileManager.default.fileExists(atPath: repo.store.appendingPathComponent("scratch.999998").path))
    }

    @Test("Los puntos se nombran con un contador (un reloj que retrocede no los desordena)")
    func counterNames() throws {
        let repo = try makeRepo()
        for index in 0..<3 {
            try repo.write("a.txt", "v\(index)\n")
            _ = try snapshot(repo)
        }
        let names = try repo.storeGit("for-each-ref --format='%(refname)' refs/checkpoints/").stdout
            .split(separator: "\n").map(String.init)
        #expect(names == ["refs/checkpoints/0000000001", "refs/checkpoints/0000000002", "refs/checkpoints/0000000003"])
    }
}
