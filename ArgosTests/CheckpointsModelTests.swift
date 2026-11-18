//
//  CheckpointsModelTests.swift
//  ArgosTests
//
//  `CheckpointsModel` de punta a punta con un `sh` local en lugar de SSH (mismos comandos
//  que viajarían al servidor), el parser con salidas fijas y el instalador de hooks.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("CheckpointsModel", .serialized)
struct CheckpointsModelTests {

    private func makeRepo() throws -> CheckpointRepo {
        let repo = try CheckpointRepo(name: "mi proyecto")
        try repo.write("a.txt", "uno\n")
        try repo.git("add -A && git commit -qm inicial")
        return repo
    }

    @Test("Lista los turnos, el diff de cada turno y deshace hasta un punto con confirmación")
    func fullFlow() async throws {
        let repo = try makeRepo()
        try repo.hook(prompt: "Primer turno")
        try repo.write("a.txt", "turno 1\n")
        try repo.write("nuevo.txt", "creado en el turno 1\n")
        try repo.hook(prompt: "Segundo turno")
        try repo.write("a.txt", "turno 2\n")

        let model = CheckpointsModel(path: repo.repo.path, run: repo.runner)
        await model.refresh()
        let checkpoints = model.checkpoints
        try #require(checkpoints.count == 2)
        #expect(checkpoints.map(\.title) == ["Segundo turno", "Primer turno"])
        #expect(checkpoints.map(\.changedFiles) == [1, 2])

        // Turno 1 (el más antiguo): de su punto al siguiente.
        await model.select(checkpoints[1].id)
        guard case .loaded(let files) = model.files else { Issue.record("sin archivos"); return }
        #expect(Set(files.map(\.path)) == ["a.txt", "nuevo.txt"])
        await model.selectFile("a.txt")
        guard case .loaded(let diff) = model.diffState else { Issue.record("sin diff"); return }
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "turno 1" })

        await model.setComparison(.sinceThen)
        guard case .loaded(let since) = model.files else { Issue.record("sin archivos"); return }
        #expect(Set(since.map(\.path)) == ["a.txt", "nuevo.txt"])

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

    @Test("Restaurar un archivo y crear un punto a mano")
    func singleFileAndManual() async throws {
        let repo = try makeRepo()
        try repo.hook()
        try repo.write("a.txt", "cambiado\n")
        let model = CheckpointsModel(path: repo.repo.path, run: repo.runner)
        await model.refresh()
        let point = try #require(model.checkpoints.first)
        await model.restoreFile("a.txt", from: point)
        #expect(repo.read("a.txt") == "uno\n")
        #expect(model.notice?.contains("a.txt") == true)

        try repo.write("a.txt", "otro\n")
        await model.createSnapshot()
        #expect(model.checkpoints.first?.kind == .manual)
    }

    @Test("Carpeta sin git y desactivar en el servidor")
    func notRepositoryAndToggle() async throws {
        let repo = try makeRepo()
        let outside = repo.base.appendingPathComponent("suelta")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let loose = CheckpointsModel(path: outside.path, run: repo.runner)
        await loose.refresh()
        #expect(loose.state == .notRepository)

        let model = CheckpointsModel(path: repo.repo.path, run: repo.runner)
        await model.refresh()
        #expect(model.isEnabledOnServer)
        await model.setEnabledOnServer(false)
        #expect(!model.isEnabledOnServer)
        #expect(FileManager.default.fileExists(atPath: repo.home.appendingPathComponent(CheckpointScript.serverOffRelativePath).path))
        await model.setEnabledOnServer(true)
        #expect(model.isEnabledOnServer)
    }

    @Test("Rebase en curso: la vista previa avisa y no deja nada pendiente")
    func busyRefuses() async throws {
        let repo = try makeRepo()
        try repo.hook()
        try repo.write("a.txt", "cambio\n")
        let model = CheckpointsModel(path: repo.repo.path, run: repo.runner)
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
            Checkpoint(ref: "refs/argos/checkpoints/main/\($0)", commit: $0, parent: nil, date: Date(),
                       kind: .prompt, sessionID: nil, label: $0, changedFiles: nil)
        }
        func pair(_ index: Int, _ comparison: CheckpointComparison) -> String? {
            CheckpointsModel.range(index: index, in: points, comparison: comparison).map { "\($0.from)>\($0.to)" }
        }
        #expect(pair(2, .turn) == "c1>c2")
        #expect(pair(0, .turn) == "c3>-")
        #expect(pair(2, .sinceThen) == "c1>-")
        #expect(CheckpointsModel.range(index: 5, in: points, comparison: .turn) == nil)
    }
}

@Suite("CheckpointParser")
struct CheckpointParserTests {

    @Test("Lista: ignora la basura del perfil y lee metadatos, recuentos y omisiones")
    func parsesList() throws {
        let output = "Bienvenido al servidor\nARGOS_CP_LIST 1\nARGOS_CP_STATE off-repo\nARGOS_CP_ROOT /srv/app\n"
            + "ARGOS_CP_SKIPPED 1800000000 archivo nuevo de mas de 20 MB: data.bin\nARGOS_CP_HEAD abc\n"
            + "ARGOS_CP_COUNT c2 3\nARGOS_CP_COUNT c1 1\nARGOS_CP_META\n"
            + "refs/argos/checkpoints/main/1800000100\u{1f}c2\u{1f}abc\u{1f}1800000100\u{1f}Haz \"x\" ñ\n\nArgos-Checkpoint: 1\nArgos-Kind: prompt\nArgos-Session: s-1\n\u{1e}\n"
            + "refs/argos/checkpoints/main/1800000000\u{1f}c1\u{1f}\u{1f}1800000000\u{1f}Antes de restaurar: x\n\nArgos-Kind: restore\nArgos-Session: -\n\u{1e}\n"
        guard case .listing(let listing) = try CheckpointParser.parseList(output) else {
            Issue.record("no es una lista"); return
        }
        #expect(listing.root == "/srv/app")
        #expect(listing.state == .offRepo)
        #expect(listing.headCommit == "abc")
        #expect(listing.lastSkip?.reason.contains("data.bin") == true)
        #expect(listing.checkpoints.map(\.commit) == ["c2", "c1"])
        #expect(listing.checkpoints[0].label == "Haz \"x\" ñ")
        #expect(listing.checkpoints[0].sessionID == "s-1")
        #expect(listing.checkpoints[0].changedFiles == 3)
        #expect(listing.checkpoints[1].kind == .restore)
        #expect(listing.checkpoints[1].parent == nil)
        #expect(listing.checkpoints[1].sessionID == nil)
    }

    @Test("Estados especiales y errores")
    func specialStates() throws {
        #expect(try CheckpointParser.parseList("ARGOS_CP_NOREPO\n") == .notRepository)
        #expect(try CheckpointParser.parseList("ARGOS_CP_NOGIT\n") == .gitMissing)
        #expect(throws: CheckpointError.busy("MERGE_HEAD")) { try CheckpointParser.parseRestore("ARGOS_CP_BUSY MERGE_HEAD\n") }
        #expect(throws: CheckpointError.badReference) { try CheckpointParser.parseFiles("ARGOS_CP_BADREF\n") }
        #expect(throws: CheckpointError.self) { try CheckpointParser.parseList("algo raro") }
        #expect(CheckpointError.busy("rebase-merge").errorDescription?.contains("rebase") == true)
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

@Suite("ClaudeHookInstaller · puntos de restauración")
struct CheckpointHookInstallerTests {

    private func commands(_ settings: [String: Any], event: String) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test("Instalación nueva: añade el hook de captura en UserPromptSubmit con su plazo")
    func freshInstall() throws {
        let installed = ClaudeHookInstaller.installing(into: [:])
        let prompt = commands(installed, event: "UserPromptSubmit")
        #expect(prompt.contains(ClaudeHookInstaller.checkpointCommand))
        #expect(prompt.contains(ClaudeHookInstaller.command(setting: .working)))
        #expect(ClaudeHookInstaller.checkpointCommand.contains(ClaudeHookInstaller.marker))
        #expect(ClaudeHookInstaller.checkpointCommand.contains(CheckpointScript.installedRelativePath))
        #expect(ClaudeHookInstaller.isInstalled(in: installed))
        let serialized = try ClaudeHookInstaller.serialize(installed)
        #expect(serialized.contains("\"timeout\" : 15"))
    }

    @Test("Actualización desde la versión anterior (sin el hook de captura)")
    func upgradeFromPrevious() throws {
        var previous = ClaudeHookInstaller.installing(into: [:])
        var hooks = try #require(previous["hooks"] as? [String: Any])
        var groups = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        groups.removeAll { group in
            (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == ClaudeHookInstaller.checkpointCommand } == true
        }
        hooks["UserPromptSubmit"] = groups
        previous["hooks"] = hooks
        #expect(ClaudeHookInstaller.hasAnyOurs(in: previous))
        #expect(!ClaudeHookInstaller.isInstalled(in: previous))
        let upgraded = ClaudeHookInstaller.installing(into: previous)
        #expect(ClaudeHookInstaller.isInstalled(in: upgraded))
        #expect(commands(upgraded, event: "UserPromptSubmit").count == 2)
    }

    @Test("Convive con hooks ajenos y desinstalar los quita todos los nuestros")
    func coexistsAndUninstalls() throws {
        let existing = try ClaudeHookInstaller.parseSettings("""
        {"env":{"K":"v"},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 mio.py"}]}]}}
        """)
        let installed = ClaudeHookInstaller.installing(into: existing)
        #expect(commands(installed, event: "UserPromptSubmit").contains("python3 mio.py"))
        let removed = ClaudeHookInstaller.removing(from: installed)
        #expect(commands(removed, event: "UserPromptSubmit") == ["python3 mio.py"])
        #expect((removed["env"] as? [String: Any])?["K"] as? String == "v")
        #expect(!ClaudeHookInstaller.hasAnyOurs(in: removed))
    }
}
