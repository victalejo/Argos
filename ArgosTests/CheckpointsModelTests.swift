//
//  CheckpointsModelTests.swift
//  ArgosTests
//
//  `CheckpointsModel` de punta a punta con un `sh` local en lugar de SSH (mismos comandos
//  que viajarían al servidor), el parser con salidas fijas y el instalador del hook.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("CheckpointsModel", .serialized)
struct CheckpointsModelTests {

    private func makeRepo(enabled: Bool = true) throws -> CheckpointRepo {
        let repo = try CheckpointRepo(name: "mi proyecto", enabled: enabled)
        try repo.write("a.txt", "uno\n")
        try repo.git("add -A && git commit -qm inicial")
        return repo
    }

    private func model(_ repo: CheckpointRepo, hooks: FakeCheckpointHooks = FakeCheckpointHooks(),
                       activity: ClaudeActivity? = nil) -> CheckpointsModel {
        CheckpointsModel(path: repo.repo.path, run: repo.runner, hooks: hooks.control) { activity }
    }

    @Test("Activar instala el hook la primera vez y escribe argos.checkpoints en el repo")
    func enableInstallsHook() async throws {
        let repo = try makeRepo(enabled: false)
        let hooks = FakeCheckpointHooks()
        let model = model(repo, hooks: hooks)
        await model.refresh()
        #expect(!model.isEnabled)
        await model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(hooks.installs == 1)
        #expect(try repo.git("config --bool argos.checkpoints").stdout == "true\n")
        await model.setEnabled(false)
        #expect(!model.isEnabled)
        await model.setEnabled(true)
        #expect(hooks.installs == 1, "ya estaba instalado")
        await model.removeFromServer()
        #expect(hooks.uninstalls == 1)
        #expect(!model.isEnabled)
    }

    @Test("Lista los turnos, el diff de cada turno y deshace hasta un punto con confirmación")
    func fullFlow() async throws {
        let repo = try makeRepo()
        try repo.hook(prompt: "Primer turno")
        try repo.write("a.txt", "turno 1\n")
        try repo.write("nuevo.txt", "creado en el turno 1\n")
        try repo.hook(prompt: "Segundo turno")
        try repo.write("a.txt", "turno 2\n")

        let model = model(repo)
        await model.refresh()
        let checkpoints = model.checkpoints
        try #require(checkpoints.count == 2)
        #expect(checkpoints.map(\.title) == ["Turno 2", "Turno 1"])
        #expect(checkpoints.map(\.changedFiles) == [1, 2])

        await model.select(checkpoints[1].id)
        guard case .loaded(let files) = model.files else { Issue.record("sin archivos"); return }
        #expect(Set(files.map(\.path)) == ["a.txt", "nuevo.txt"])
        await model.selectFile("a.txt")
        guard case .loaded(let diff) = model.diffState else { Issue.record("sin diff"); return }
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "turno 1" })
        #expect(!model.canRestoreFile, "en «Este turno» no se restaura un archivo")

        await model.setComparison(.sinceThen)
        #expect(model.canRestoreFile)

        await model.prepareRestore(checkpoints[1])
        let preview = try #require(model.pendingRestore)
        #expect(preview.toModify == ["a.txt"])
        #expect(preview.toDelete == ["nuevo.txt"])
        await model.confirmRestore()
        #expect(model.errorMessage == nil)
        #expect(repo.read("a.txt") == "uno\n")
        #expect(!repo.exists("nuevo.txt"))
        #expect(model.checkpoints.first?.kind == .restore)
    }

    @Test("Restaurar un archivo desde «Hasta ahora» y crear un punto a mano")
    func singleFileAndManual() async throws {
        let repo = try makeRepo()
        try repo.hook()
        try repo.write("a.txt", "cambiado\n")
        let model = model(repo)
        await model.refresh()
        await model.select(try #require(model.checkpoints.first).id)
        await model.setComparison(.sinceThen)
        await model.restoreFile("a.txt")
        #expect(repo.read("a.txt") == "uno\n")
        #expect(model.notice?.contains("a.txt") == true)

        try repo.write("a.txt", "otro\n")
        await model.createSnapshot()
        #expect(model.checkpoints.first?.kind == .manual)
    }

    @Test("Restaurar un archivo que cambió después de listarlo: no toca nada")
    func singleFileChangedSinceListing() async throws {
        let repo = try makeRepo()
        try repo.hook()
        try repo.write("a.txt", "cambio 1\n")
        let model = model(repo)
        await model.refresh()
        await model.select(try #require(model.checkpoints.first).id)
        await model.setComparison(.sinceThen)
        try repo.write("a.txt", "cambio 2\n")
        await model.restoreFile("a.txt")
        #expect(repo.read("a.txt") == "cambio 2\n")
        #expect(model.errorMessage != nil)
    }

    @Test("Con Claude trabajando, restaurar exige confirmarlo expresamente")
    func workingNeedsAcknowledgement() async throws {
        let repo = try makeRepo()
        try repo.hook()
        try repo.write("a.txt", "cambio\n")
        let model = model(repo, activity: .working)
        await model.refresh()
        let point = try #require(model.checkpoints.first)
        await model.prepareRestore(point)
        #expect(model.claudeIsWorking)
        await model.confirmRestore()
        #expect(repo.read("a.txt") == "cambio\n")
        #expect(model.pendingRestore != nil)
        await model.confirmRestore(acknowledgingWork: true)
        #expect(repo.read("a.txt") == "uno\n")
    }

    @Test("Conflictos: la vista previa no deja restaurar y no se toca nada")
    func conflictsBlock() async throws {
        let repo = try makeRepo()
        try repo.write("lib", "v1\n")
        try repo.hook()
        try repo.remove("lib")
        try repo.write("lib/dentro.txt", "x\n")
        try repo.write(".gitignore", "*.local\n")
        try repo.write("lib/secreto.local", "S\n")
        let model = model(repo)
        await model.refresh()
        await model.prepareRestore(try #require(model.checkpoints.first))
        let preview = try #require(model.pendingRestore)
        #expect(!preview.canRestore)
        await model.confirmRestore()
        #expect(repo.read("lib/secreto.local") == "S\n")
    }

    @Test("Carpeta sin git")
    func notRepository() async throws {
        let repo = try makeRepo()
        let outside = repo.base.appendingPathComponent("suelta")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let loose = CheckpointsModel(path: outside.path, run: repo.runner, hooks: FakeCheckpointHooks().control)
        await loose.refresh()
        #expect(loose.state == .notRepository)
    }

    @Test("Rebase en curso: la vista previa avisa y no deja nada pendiente")
    func busyRefuses() async throws {
        let repo = try makeRepo()
        try repo.hook()
        try repo.write("a.txt", "cambio\n")
        let model = model(repo)
        await model.refresh()
        try FileManager.default.createDirectory(at: repo.repo.appendingPathComponent(".git/rebase-apply"),
                                                withIntermediateDirectories: true)
        await model.prepareRestore(try #require(model.checkpoints.first))
        #expect(model.pendingRestore == nil)
        #expect(model.errorMessage?.contains("rebase") == true)
    }

    @Test("Rango comparado: turno hasta el siguiente punto, el último hasta ahora")
    func ranges() {
        let points = ["c3", "c2", "c1"].map {
            Checkpoint(ref: "refs/checkpoints/\($0)", commit: $0, parent: nil, date: Date(),
                       kind: .prompt, sessionID: nil, label: $0, changedFiles: nil)
        }
        func pair(_ index: Int, _ comparison: CheckpointComparison) -> String? {
            CheckpointsModel.range(index: index, in: points, comparison: comparison).map { "\($0.from)>\($0.to)" }
        }
        #expect(pair(2, .turn) == "c1>c2")
        #expect(pair(0, .turn) == "c3>-")
        #expect(pair(2, .sinceThen) == "c1>-")
        #expect(pair(5, .turn) == nil)
    }
}

@Suite("CheckpointParser")
struct CheckpointParserTests {

    @Test("Lista: ignora la basura del perfil y lee metadatos, recuentos y omisiones")
    func parsesList() throws {
        let output = "Bienvenido al servidor\nARGOS_CP_LIST 2\nARGOS_CP_STATE on\nARGOS_CP_PROMPTS off\nARGOS_CP_ROOT /srv/app\n"
            + "ARGOS_CP_HEAD abc\nARGOS_CP_SKIPLOG 1800000050 archivo de mas de 20 MB: data.bin\n"
            + "ARGOS_CP_COUNT c2 3\nARGOS_CP_COUNT c1 1\nARGOS_CP_META\n"
            + "refs/checkpoints/1800000100\u{1f}c2\u{1f}abc\u{1f}1800000100\u{1f}Turno 2\n\nArgos-Checkpoint: 1\nArgos-Kind: prompt\nArgos-Session: s-1\n\u{1e}\n"
            + "refs/checkpoints/1800000000\u{1f}c1\u{1f}\u{1f}1800000000\u{1f}Antes de restaurar: x\n\nArgos-Kind: restore\nArgos-Session: -\n\u{1e}\n"
        guard case .listing(let listing) = try CheckpointParser.parseList(output) else {
            Issue.record("no es una lista"); return
        }
        #expect(listing.root == "/srv/app")
        #expect(listing.isEnabled && !listing.storesPrompts)
        #expect(listing.headCommit == "abc")
        #expect(listing.checkpoints.map(\.commit) == ["c2", "c1"])
        #expect(listing.checkpoints[0].sessionID == "s-1")
        #expect(listing.checkpoints[0].changedFiles == 3)
        #expect(listing.checkpoints[1].kind == .restore)
        #expect(listing.checkpoints[1].parent == nil)
        #expect(listing.skips(duringTurnAt: 1).map(\.reason) == ["archivo de mas de 20 MB: data.bin"])
        #expect(listing.skips(duringTurnAt: 0).isEmpty)
    }

    @Test("Estados especiales y errores")
    func specialStates() throws {
        #expect(try CheckpointParser.parseList("ARGOS_CP_NOREPO\n") == .notRepository)
        #expect(try CheckpointParser.parseList("ARGOS_CP_NOGIT\n") == .gitMissing)
        #expect(throws: CheckpointError.busy("MERGE_HEAD")) { try CheckpointParser.parseRestore("ARGOS_CP_BUSY MERGE_HEAD\n") }
        #expect(throws: CheckpointError.badReference) { try CheckpointParser.parseFiles("ARGOS_CP_BADREF\n") }
        #expect(throws: CheckpointError.heavy("x")) { try CheckpointParser.parseFiles("ARGOS_CP_HEAVY x\n") }
        #expect(throws: CheckpointError.self) { try CheckpointParser.parseList("algo raro") }
        #expect(try CheckpointParser.parseRestore("ARGOS_CP_NOOP invalid\n") == .nothing(CheckpointParser.noopText("invalid")))
        let conflict = try CheckpointParser.parseRestore("ARGOS_CP_NEW abc\nARGOS_CP_CONFLICT\nD\0lib\0R\0v/x.c\0END\0\0\n")
        #expect(conflict == .conflict([CheckpointIssue(kind: .directoryInTheWay, path: "lib"),
                                       CheckpointIssue(kind: .nestedRepository, path: "v/x.c")]))
    }

    @Test("name-status separado por NUL, con rutas que contienen saltos de línea")
    func nameStatus() {
        let changes = CheckpointParser.parseNameStatus("M\0a b.txt\0A\0x\ny\0D\0borrado\0T\0enlace\0")
        #expect(changes.map(\.path) == ["a b.txt", "x\ny", "borrado", "enlace"])
        #expect(changes.map(\.kind) == [.modified, .added, .deleted, .typeChanged])
    }

    @Test("El extracto recortado por bytes no deja caracteres rotos")
    func cleansLabel() {
        #expect(CheckpointParser.cleanLabel("hola \u{FFFD}...") == "hola …")
        #expect(CheckpointParser.cleanLabel(" normal ") == "normal")
    }
}

@Suite("CheckpointHookInstaller")
struct CheckpointHookInstallerTests {

    private func commands(_ settings: [String: Any], event: String) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test("La instalación normal del indicador queda exactamente igual que el golden de antes")
    func normalInstallUnchanged() throws {
        let golden = GoldenParityTests.directory.appendingPathComponent("hooks-empty.txt")
        let expected = try String(contentsOf: golden, encoding: .utf8)
        #expect(try ClaudeHookInstaller.serialize(ClaudeHookInstaller.installing(into: [:])) == expected)
        #expect(!expected.contains(CheckpointHookInstaller.marker))
        #expect(!CheckpointHookInstaller.command.contains(ClaudeHookInstaller.marker))
    }

    @Test("El hook de captura se instala aparte y el indicador no lo toca al reinstalar ni al quitar")
    func separateFromStatusHooks() throws {
        let status = ClaudeHookInstaller.installing(into: [:])
        let both = CheckpointHookInstaller.installing(into: status)
        #expect(CheckpointHookInstaller.isInstalled(in: both))
        #expect(ClaudeHookInstaller.isInstalled(in: both))
        #expect(commands(both, event: "UserPromptSubmit").contains(CheckpointHookInstaller.command))
        let reinstalled = ClaudeHookInstaller.installing(into: both)
        #expect(CheckpointHookInstaller.isInstalled(in: reinstalled))
        let statusRemoved = ClaudeHookInstaller.removing(from: both)
        #expect(CheckpointHookInstaller.isInstalled(in: statusRemoved))
        let removed = CheckpointHookInstaller.removing(from: both)
        #expect(try ClaudeHookInstaller.serialize(removed) == ClaudeHookInstaller.serialize(status))
        #expect(!CheckpointHookInstaller.hasAny(in: status))
    }

    @Test("Convive con hooks ajenos e instalar dos veces no duplica")
    func coexistsAndIdempotent() throws {
        let existing = try ClaudeHookInstaller.parseSettings("""
        {"env":{"K":"v"},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 mio.py"}]}]}}
        """)
        let once = CheckpointHookInstaller.installing(into: existing)
        let twice = CheckpointHookInstaller.installing(into: once)
        #expect(try ClaudeHookInstaller.serialize(once) == ClaudeHookInstaller.serialize(twice))
        #expect(commands(once, event: "UserPromptSubmit") == ["python3 mio.py", CheckpointHookInstaller.command])
        let removed = CheckpointHookInstaller.removing(from: once)
        #expect(commands(removed, event: "UserPromptSubmit") == ["python3 mio.py"])
        #expect((removed["env"] as? [String: Any])?["K"] as? String == "v")
    }
}
