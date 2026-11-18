//
//  IntegrationCheckpointTests.swift
//  ArgosTests
//
//  Puntos de restauración contra un servidor real (sshd temporal de macOS en la CI, o un
//  Linux con dash por un túnel; ver `IntegrationRemote`): activar e instalar el hook,
//  captura por el hook tal como lo ejecuta Claude Code, límites y plazo, lista, diff,
//  vista previa, restaurar (todo y un archivo) y deshacer, que los puntos no viajan,
//  worktree enlazado y el hook disparado por el `claude` simulado. Los casos de seguridad
//  están en `IntegrationCheckpointSafetyTests`.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Puntos de restauración en el servidor")
@MainActor
struct Checkpoints {

    private var settingsPath: String { ".claude/settings.json" }

    private func settings(_ repo: RemoteCheckpointRepo) async throws -> [String: Any] {
        let text = try await repo.box.read("\(repo.box.home)/\(settingsPath)")
        return try ClaudeHookInstaller.parseSettings(text)
    }

    /// Deja `~/.claude/settings.json` y el script como estaban antes del test.
    private func resetHooks(_ repo: RemoteCheckpointRepo) async {
        _ = try? await repo.box.sh("rm -f \"$HOME/\(settingsPath)\" \"$HOME/\(CheckpointScript.installedRelativePath)\"")
    }

    @Test("Activar por proyecto instala el hook junto al de estado; quitarlo deja el de estado", .timeLimit(.minutes(3)))
    func activateInstallsHook() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-activate", enabled: false) else { return }
        await resetHooks(repo)
        defer { IntegrationCleanup.later { await resetHooks(repo); await repo.close() } }
        try await repo.box.service.installClaudeHooks()

        let model = CheckpointsModel(path: repo.path, service: repo.box.service)
        await model.refresh()
        #expect(model.listing?.root == repo.path)
        #expect(model.isEnabled == false)
        #expect(try await repo.box.service.checkpointHookInstalled() == false)

        await model.setEnabled(true)
        #expect(model.errorMessage == nil, "\(model.errorMessage ?? "")")
        #expect(model.isEnabled)
        let installed = try await settings(repo)
        #expect(CheckpointHookInstaller.isInstalled(in: installed))
        #expect(ClaudeHookInstaller.isInstalled(in: installed), "el hook de estado sigue")
        #expect(try await repo.box.service.checkpointHookInstalled())
        #expect(try await repo.box.service.upgradeCheckpointHookIfOutdated() == false)
        let mode = try await repo.box.sh("ls -l \"$HOME/\(CheckpointScript.installedRelativePath)\" | cut -c1-10")
        #expect(mode.hasPrefix("-rw-------"), "permisos del script: \(mode)")

        // Cada hook de UserPromptSubmit (el de estado y el de puntos), como lo haría Claude.
        let commands = (installed["hooks"] as? [String: Any])?[CheckpointHookInstaller.event] as? [[String: Any]] ?? []
        let handlers = commands.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
        #expect(handlers.contains(CheckpointHookInstaller.command))
        try await repo.write("a.txt", "turno 1\n")
        for command in handlers {
            let run = try await repo.hook(command: command)
            #expect(run.output.exitCode == 0 && run.output.stdout.isEmpty, "\(command): \(run.output)")
        }
        #expect(try await repo.points().count == 1)

        await model.removeFromServer()
        #expect(model.errorMessage == nil, "\(model.errorMessage ?? "")")
        #expect(model.isEnabled == false)
        let removed = try await settings(repo)
        #expect(!CheckpointHookInstaller.hasAny(in: removed))
        #expect(ClaudeHookInstaller.isInstalled(in: removed))
        #expect(try await !repo.box.exists("\(repo.box.home)/\(CheckpointScript.installedRelativePath)"))
        #expect(try await !repo.box.exists(repo.store), "desactivar borra los puntos")
    }

    @Test("El hook captura modificados, nuevos y borrados (no ignorados), en silencio y con 0", .timeLimit(.minutes(3)))
    func hookCapturesTurn() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-hook") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        try await repo.write(".gitignore", "*.log\n")
        try await repo.write("borrar.txt", "b\n")
        try await repo.sh("git add -A && git commit -qm previo && rm borrar.txt")
        try await repo.write("a.txt", "modificado\n")
        try await repo.write("nuevo.txt", "nuevo\n")
        try await repo.write("salida.log", "ignorado\n")

        let start = ContinuousClock.now
        let run = try await repo.hook(prompt: "Primer turno")
        let wall = ContinuousClock.now - start
        #expect(run.output.exitCode == 0)
        #expect(run.output.stdout.isEmpty && run.output.stderr.isEmpty, "nada por stdout/stderr: \(run.output)")
        #expect(run.seconds < 6 && wall < .seconds(15), "hook: \(run.seconds) s en el servidor, \(wall) en total")
        let point = try #require(try await repo.points().first)
        #expect(try await repo.show(point, "a.txt") == "modificado\n")
        #expect(try await repo.show(point, "nuevo.txt") == "nuevo\n")
        #expect(try await repo.show(point, "borrar.txt") == nil)
        #expect(try await repo.show(point, "salida.log") == nil)
        #expect(try await repo.waitSealed(point), "sellado en segundo plano")

        // Mismo árbol: no se repite; otro cambio: otro punto.
        try await repo.hook(prompt: "Sin cambios")
        #expect(try await repo.points().count == 1)
        try await repo.write("a.txt", "otra vez\n")
        try await repo.hook(prompt: "Segundo turno")
        #expect(try await repo.points().count == 2)
        let mode = try await repo.sh("ls -ld .git/\(CheckpointScript.storeName) | cut -c1-10")
        #expect(mode.hasPrefix("drwx------"))
        #expect(try await repo.sh("git status --porcelain") == " M a.txt\n D borrar.txt\n?? nuevo.txt\n", "el índice real no se toca")
    }

    @Test("Sin argos.checkpoints=true, fuera de un repo o sin script, el hook no hace nada", .timeLimit(.minutes(2)))
    func hookDoesNothingWhenOff() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-off", enabled: false) else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.write("a.txt", "cambio\n")
        let missing = try await repo.hook()
        #expect(missing.output.exitCode == 0 && missing.output.stdout.isEmpty, "sin script instalado")
        try await repo.installScript()
        let off = try await repo.hook()
        #expect(off.output.exitCode == 0 && off.output.stdout.isEmpty)
        #expect(try await !repo.box.exists(repo.store))
        try await repo.sh("mkdir -p ../fuera")
        let outside = try await repo.hook(in: repo.zone + "/fuera")
        #expect(outside.output.exitCode == 0 && outside.output.stdout.isEmpty)
        #expect(try await !repo.box.exists(repo.zone + "/fuera/.git"))
    }

    @Test("Límites del hook: 20 MB por archivo y 50 MB por turno (stat, xargs -0), rápido y con motivo", .timeLimit(.minutes(3)))
    func hookSizeLimits() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-limits") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        try await repo.hook()
        let before = try await repo.points().count
        try await repo.big("volcado \"2\"\n.bin", megabytes: 25)
        let single = try await repo.hook(prompt: "grande")
        #expect(single.seconds < 4, "\(single.seconds) s")
        #expect(try await repo.points().count == before)
        #expect(try await repo.skips().contains("20 MB"))
        try await repo.sh("rm -f ./volcado*")
        for index in 0..<6 { try await repo.big("trozo \(index).bin", megabytes: 9) }
        let total = try await repo.hook(prompt: "total")
        #expect(total.seconds < 4, "\(total.seconds) s")
        #expect(try await repo.points().count == before)
        #expect(try await repo.skips().contains("50 MB"))
        let size = try await repo.sh("du -sk .git | cut -f1").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((Int(size) ?? .max) < 10_000, ".git ocupa \(size) KB")
        let listing = try await repo.list()
        #expect(listing.skips.last?.reason.contains("50 MB") == true)
    }

    @Test("Plazo global: 20.000 archivos y 1.900 modificados dentro del plazo del hook", .timeLimit(.minutes(5)))
    func hookDeadlineOnBigRepository() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-big") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        try await repo.sh("i=0; while [ $i -lt 200 ]; do mkdir -p src/d$i; j=0; while [ $j -lt 100 ]; do "
            + "echo \"$i $j\" > src/d$i/f$j; j=$((j+1)); done; i=$((i+1)); done; git add -A && git commit -qm big")
        let first = try await repo.hook()
        try await repo.sh("i=0; while [ $i -lt 1900 ]; do echo mod >> src/d$((i/100))/f$((i%100)); i=$((i+1)); done")
        let second = try await repo.hook(prompt: "muchos")
        #expect(first.seconds < 8 && second.seconds < 8, "hook: \(first.seconds) s y \(second.seconds) s")
        #expect(first.output.exitCode == 0 && second.output.exitCode == 0)
        let point = try #require(try await repo.points().first)
        #expect(try await repo.show(point, "src/d18/f99") == "18 99\nmod\n")
    }

    @Test("Lista, archivos del turno y «hasta ahora», diff y vista previa (con el modelo)", .timeLimit(.minutes(3)))
    func listDiffAndPreview() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-list") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        try await repo.sh("git config argos.checkpointsPrompt true")
        try await repo.write("a.txt", "turno 1\n")
        try await repo.hook(prompt: "Primero «ñandú» \"citas\"")
        try await repo.write("a.txt", "turno 2\n")
        try await repo.write("b.txt", "nuevo\n")
        try await repo.hook(prompt: "Segundo")
        try await repo.write("a.txt", "ahora\n")

        let model = CheckpointsModel(path: repo.path, service: repo.box.service)
        await model.refresh()
        let listing = try #require(model.listing)
        #expect(listing.isEnabled && listing.storesPrompts)
        #expect(listing.checkpoints.map(\.label) == ["Segundo", "Primero «ñandú» \"citas\""])
        #expect(listing.checkpoints.map(\.changedFiles) == [1, 2], "recuentos: \(listing.checkpoints.map(\.changedFiles))")
        #expect(listing.checkpoints.allSatisfy { $0.sessionID == "sesion-it" && $0.kind == .prompt && !$0.isDamaged })

        let first = try #require(listing.checkpoints.last)
        await model.select(first.id)
        #expect(model.files == .loaded([
            CheckpointFileChange(path: "a.txt", kind: .modified), CheckpointFileChange(path: "b.txt", kind: .added),
        ]))
        await model.setComparison(.sinceThen)
        #expect(model.files == .loaded([
            CheckpointFileChange(path: "a.txt", kind: .modified), CheckpointFileChange(path: "b.txt", kind: .added),
        ]))
        await model.selectFile("a.txt")
        guard case .loaded(let diff) = model.diffState else {
            Issue.record("sin diff: \(model.diffState)"); return
        }
        #expect(diff.additions == 1 && diff.deletions == 1)
        let raw = try await repo.command(CheckpointCommands.diff(root: repo.path, from: first.commit, to: "-", path: "a.txt"))
        #expect(raw.contains("-turno 1") && raw.contains("+ahora"))

        await model.prepareRestore(first)
        let preview = try #require(model.pendingRestore)
        #expect(preview.toModify == ["a.txt"] && preview.toDelete == ["b.txt"] && preview.toRecreate.isEmpty)
        #expect(preview.canRestore && preview.commitsSince == 0)
        model.cancelRestore()
        #expect(try await repo.read("a.txt") == "ahora\n", "la vista previa no toca nada")
    }

    @Test("Restaurar todo y un archivo con la copia previa, y deshacer la restauración", .timeLimit(.minutes(3)))
    func restoreAndUndo() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-restore") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        try await repo.write("a.txt", "punto\n")
        try await repo.write("dir/b.txt", "b punto\n")
        try await repo.hook(prompt: "Punto")
        try await repo.write("a.txt", "después\n")
        try await repo.sh("rm dir/b.txt")
        try await repo.hook(prompt: "Después")
        // Lo que Claude hizo en el último turno (sin punto aún): solo lo guarda la copia previa.
        try await repo.write("c.txt", "creado después\n")

        let model = CheckpointsModel(path: repo.path, service: repo.box.service)
        await model.refresh()
        let target = try #require(model.checkpoints.last)
        await model.prepareRestore(target)
        #expect(model.pendingRestore?.canRestore == true)
        await model.confirmRestore()
        #expect(model.errorMessage == nil, "\(model.errorMessage ?? "")")
        #expect(model.notice != nil)
        #expect(try await repo.read("a.txt") == "punto\n")
        #expect(try await repo.read("dir/b.txt") == "b punto\n")
        #expect(try await !repo.exists("c.txt"))
        let backup = try #require(model.checkpoints.first)
        #expect(backup.kind == .restore && backup.label.hasPrefix("Antes de restaurar"))
        #expect(try await repo.show(backup.commit, "c.txt") == "creado después\n")

        // Deshacer: restaurar la copia previa.
        await model.prepareRestore(backup)
        await model.confirmRestore()
        #expect(model.errorMessage == nil, "\(model.errorMessage ?? "")")
        #expect(try await repo.read("a.txt") == "después\n")
        #expect(try await repo.read("c.txt") == "creado después\n")
        #expect(try await !repo.exists("dir/b.txt"))

        // Un archivo («Hasta ahora»): solo ese, con su copia previa.
        try await repo.write("a.txt", "editado a mano\n")
        await model.refresh()
        let point = try #require(model.checkpoints.last, "el más antiguo es el primer turno")
        await model.select(point.id)
        await model.setComparison(.sinceThen)
        await model.restoreFile("a.txt")
        #expect(model.errorMessage == nil, "\(model.errorMessage ?? "")")
        #expect(try await repo.read("a.txt") == "punto\n")
        #expect(try await repo.read("c.txt") == "creado después\n")
        #expect(try await repo.inLatest("a.txt") == "editado a mano\n")
    }

    @Test("Los puntos no viajan: push --mirror, log --all, clone --mirror", .timeLimit(.minutes(2)))
    func pointsDoNotTravel() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-travel") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.write("a.txt", "cambio\n")
        _ = try await repo.snapshot()
        try await repo.sh("git commit -qam segundo && git init -q --bare ../espejo.git && git push -q --mirror ../espejo.git")
        #expect(try await repo.sh("git --git-dir=../espejo.git for-each-ref --format='%(refname)'")
            .split(separator: "\n").allSatisfy { !$0.contains("checkpoint") })
        #expect(try await !repo.box.exists(repo.zone + "/espejo.git/\(CheckpointScript.storeName)"))
        #expect(try await repo.sh("git log --all --oneline | wc -l").trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        #expect(try await repo.sh("git for-each-ref --format='%(refname)'").split(separator: "\n").allSatisfy { !$0.contains("checkpoint") })
        try await repo.sh("git clone -q --mirror . ../clon.git")
        #expect(try await !repo.box.exists(repo.zone + "/clon.git/\(CheckpointScript.storeName)"))
        #expect(try await repo.sh("git --git-dir=../clon.git count-objects -v | sed -n 's/^count: //p; s/^in-pack: //p'")
            .split(separator: "\n").compactMap { Int($0) }.reduce(0, +) <= 9, "el clon no arrastra objetos de los puntos")
    }

    @Test("Worktree enlazado: almacén propio y restauración", .timeLimit(.minutes(2)))
    func linkedWorktree() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-worktree") else { return }
        defer { IntegrationCleanup.later { await repo.close() } }
        try await repo.installScript()
        let linked = repo.zone + "/enlazado"
        try await repo.sh("git worktree add -q ../enlazado -b rama")
        try await repo.write("../enlazado/a.txt", "en la rama\n")
        let run = try await repo.hook(in: linked)
        #expect(run.output.exitCode == 0)
        let gitdir = try await repo.sh("cd \"$(git rev-parse --git-dir)\" && pwd -P", in: linked).trimmingCharacters(in: .newlines)
        #expect(gitdir.hasSuffix("/worktrees/enlazado"))
        let store = gitdir + "/" + CheckpointScript.storeName
        let point = try #require(try await repo.points(store: store).first)
        #expect(try await repo.points().isEmpty, "el principal no tiene puntos del enlazado")
        try await repo.write("../enlazado/a.txt", "después\n")
        let output = try await repo.command(CheckpointCommands.preview(root: linked, commit: point, force: true))
        let tree = output.components(separatedBy: "\n").first { $0.hasPrefix("ARGOS_CP_CURRENT ") }.map { String($0.dropFirst(17)) }
        let restored = try await repo.command(CheckpointCommands.restore(root: linked, commit: point, expectedTree: tree, path: nil))
        #expect(try CheckpointParser.parseRestore(restored) == .done(backup: try await repo.points(store: store).first))
        #expect(try await repo.box.read(linked + "/a.txt") == "en la rama\n")
        #expect(try await repo.read("a.txt") == "base\n")
    }

    @Test("claude simulado: un mensaje a un agente y una línea en una sesión disparan el hook instalado", .timeLimit(.minutes(3)))
    func fakeClaudeRunsHook() async throws {
        guard let repo = try await RemoteCheckpointRepo.open("cp-claude") else { return }
        await resetHooks(repo)
        let agent = try await repo.box.launchAgent()
        defer { IntegrationCleanup.later { await repo.box.removeAgents([agent]); await resetHooks(repo); await repo.close() } }
        try await repo.box.service.installClaudeHooks()
        try await repo.box.service.installCheckpointHook()
        let workdir = agent.workingDirectory
        try await repo.sh("git init -q . && git config user.email it@argos && git config user.name 'Argos IT' && "
            + "printf '.argos-fake-*\\n' >> .git/info/exclude && echo base > f.txt && git add -A && git commit -qm i "
            + "&& git config argos.checkpoints true && echo cambio > f.txt", in: workdir)

        let session = try await repo.box.session(for: agent)
        session.attach()
        defer { session.detach() }
        #expect(try await eventually(seconds: 15) { session.link.isLive })
        #expect(await session.send("Cambia f.txt") == .sent)
        #expect(try await eventually(seconds: 20) { session.assistantTexts.contains { $0.hasSuffix(": Cambia f.txt") } })
        let store = workdir + "/.git/" + CheckpointScript.storeName
        #expect(try await eventually(seconds: 10) { try await !repo.points(store: store).isEmpty })
        let point = try #require(try await repo.points(store: store).first)
        #expect(try await repo.show(point, "f.txt", store: store) == "cambio\n")
        let calls = try await repo.box.fakeCalls(agent)
        #expect(calls.filter { $0.hasPrefix("hook UserPromptSubmit") }.allSatisfy { $0.hasSuffix("rc=0 out=0") }, "\(calls)")
        #expect(calls.contains { $0.hasPrefix("hook UserPromptSubmit") })

        // Sesión de tmux (lo que se escribe en la terminal): `claude --continue` lee líneas.
        try await repo.sh("echo otra > f.txt", in: workdir)
        let claude = repo.q(repo.box.fakeClaude + " --continue")
        if try await repo.box.has("tmux") {
            let name = "argos-it-cp-\(agent.token)"
            IntegrationCleanup.later { _ = try? await repo.box.sh("tmux kill-session -t \(name) 2>/dev/null; true") }
            try await repo.sh("tmux new-session -d -s \(name) -c \(repo.q(workdir)) \(claude)", in: workdir)
            try await Task.sleep(for: .seconds(1))
            try await repo.sh("tmux send-keys -t \(name) 'Segundo mensaje' Enter")
            #expect(try await eventually(seconds: 15) { try await repo.points(store: store).count == 2 })
            #expect(try await eventually(seconds: 10) {
                try await repo.box.sh("tmux capture-pane -p -t \(name)").contains("eco: Segundo mensaje")
            })
        } else {
            let interactive = try await repo.run("printf 'Segundo mensaje\\n' | \(claude)", in: workdir)
            #expect(interactive.stdout.contains("eco: Segundo mensaje"), "\(interactive)")
            #expect(try await repo.points(store: store).count == 2)
        }
        #expect(try await repo.inLatestOf(store: store, "f.txt") == "otra\n")
    }
}
}

extension RemoteCheckpointRepo {
    func inLatestOf(store: String, _ file: String) async throws -> String? {
        guard let point = try await points(store: store).first else { return nil }
        return try await show(point, file, store: store)
    }
}
