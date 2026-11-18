//
//  GitDataSafetyTests.swift
//  ArgosTests
//
//  Panel «Cambios» sin sorpresas: commits de miles de archivos (límite de argumentos),
//  sugerencia de mensaje acotada, huellas del diff y confirmación si lo que se va a
//  commitear cambió desde que se vio.
//

import Testing
import Foundation
@testable import Argos

@Suite("Git: límite de longitud de las órdenes")
struct GitCommandLengthTests {

    private static func many(_ count: Int, untracked: Bool = false) -> [GitFileChange] {
        (0..<count).map {
            GitFileChange(path: "src/componentes/carpeta-larga/archivo-\($0).swift", originalPath: nil,
                          indexCode: untracked ? "?" : " ", worktreeCode: untracked ? "?" : "M")
        }
    }

    @Test("Pocos archivos van en la orden; miles, por archivo de rutas")
    func inlineOrFiles() {
        #expect(GitCommands.commitFitsInline(root: "/r", message: "m", changes: Self.many(10)))
        #expect(!GitCommands.commitFitsInline(root: "/r", message: "m", changes: Self.many(3_000)))
    }

    @Test("Texto exacto del commit con --pathspec-from-file")
    func commitFromFilesText() {
        let command = GitCommands.commitFromFiles(root: "/srv/app", message: "fix: it's", stageFile: "/tmp/a", commitFile: "/tmp/b")
        let script = """
        argos_stage='/tmp/a'; argos_commit='/tmp/b'
        trap 'rm -f -- "$argos_stage" "$argos_commit"' EXIT
        case "$(git version 2>/dev/null)" in
          "git version 1."*|"git version 2."[0-9].*|"git version 2.1"[0-9].*|"git version 2.2"[0-5].*)
            echo ARGOS_GIT_TOO_OLD; exit 3;;
        esac
        git --literal-pathspecs -C '/srv/app' add -A --pathspec-from-file="$argos_stage" --pathspec-file-nul && \
        git --literal-pathspecs -C '/srv/app' commit -m 'fix: it'\\''s' --pathspec-from-file="$argos_commit" --pathspec-file-nul
        """
        #expect(command == ShellQuoting.posixShell(script))
        #expect(command.utf8.count < 1_000)
    }

    @Test("El trap borra los archivos de rutas al terminar, aunque falle (sh real)")
    func trapRemovesFiles() throws {
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        let stage = home.appendingPathComponent("lista de rutas 'a'")
        let other = home.appendingPathComponent("b")
        for url in [stage, other] { try Data("x\0".utf8).write(to: url) }
        let command = GitCommands.commitFromFiles(root: "/no-existe", message: "m", stageFile: stage.path, commitFile: other.path)
        _ = try LocalShell.run(command, home: home)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test("Las listas de rutas van separadas por NUL, con el origen de los renombrados")
    func pathspecData() {
        let changes = [
            GitFileChange(path: "a b", originalPath: nil, indexCode: " ", worktreeCode: "M"),
            GitFileChange(path: "new", originalPath: "old", indexCode: "R", worktreeCode: " "),
        ]
        let lists = GitCommands.pathspecFiles(changes)
        #expect(lists.stage == Data("a b\0new\0".utf8))
        #expect(lists.commit == Data("a b\0old\0new\0".utf8))
    }

    @Test("Detecta un git anterior a 2.26", arguments: [
        ("git version 2.25.1", true), ("git version 2.9.5", true), ("git version 1.8.3.1", true),
        ("git version 2.26.0", false), ("git version 2.43.0", false), ("git version 2.100.1", false),
    ])
    func tooOldGit(version: String, tooOld: Bool) throws {
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        // Un `git` falso que solo responde a `git version`.
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("git")
        try Data("#!/bin/sh\n[ \"$1\" = version ] && echo '\(version)'; exit 0\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let command = GitCommands.commitFromFiles(root: home.path, message: "m", stageFile: "/nonexistent-a", commitFile: "/nonexistent-b")
        let result = try LocalShell.run("PATH=\(bin.path):$PATH; \(command)", home: home)
        #expect(result.stdout.contains(GitCommands.gitTooOldMarker) == tooOld)
    }

    @Test("La sugerencia de mensaje acota los archivos y la orden cabe")
    func suggestionIsBounded() throws {
        let changes = Self.many(5_000) + Self.many(800, untracked: true).map {
            GitFileChange(path: "nuevo/" + $0.path, originalPath: nil, indexCode: "?", worktreeCode: "?")
        }
        let sample = CommitMessageSuggestion.sample(changes)
        #expect(sample.untracked.count == CommitMessageSuggestion.maxUntrackedDiffs)
        #expect(sample.tracked.count < 5_000)
        #expect(sample.omitted == (5_000 - sample.tracked.count) + (800 - CommitMessageSuggestion.maxUntrackedDiffs))
        for hasCommits in [true, false] {
            let command = CommitMessageSuggestion.command(claudePath: "/c", root: "/r", changes: changes, hasCommits: hasCommits)
            try RemoteCommandLimit.check(ShellQuoting.posixShell(command))
            #expect(command.contains("archivos más que no se muestran aquí"))
        }
        let small = CommitMessageSuggestion.command(claudePath: "/c", root: "/r", changes: Self.many(3), hasCommits: true)
        #expect(!small.contains("no se muestran"))
    }
}

@Suite("Git: huellas del diff")
struct GitFingerprintTests {

    private static let modified = GitFileChange(path: "a b.txt", originalPath: nil, indexCode: " ", worktreeCode: "M")
    private static let untracked = GitFileChange(path: "n.txt", originalPath: nil, indexCode: "?", worktreeCode: "?")
    private static let renamed = GitFileChange(path: "new", originalPath: "old", indexCode: "R", worktreeCode: " ")

    @Test("Texto exacto de la huella de cada tipo de cambio")
    func lines() {
        let git = "git --literal-pathspecs -C '/r'"
        #expect(GitFingerprint.line(root: "/r", change: Self.modified, hasCommits: true)
                == "printf '%s' 'ARGOS_FP:'; { \(git) diff --no-color --no-ext-diff --binary HEAD -- 'a b.txt'; } 2>/dev/null | cksum")
        #expect(GitFingerprint.line(root: "/r", change: Self.untracked, hasCommits: true)
                == "printf '%s' 'ARGOS_FP:'; { cat -- '/r/n.txt'; } 2>/dev/null | cksum")
        #expect(GitFingerprint.line(root: "/r", change: Self.renamed, hasCommits: false)
                == "printf '%s' 'ARGOS_FP:'; { \(git) diff --no-color --no-ext-diff --binary --cached -- 'old' 'new'; "
                + "\(git) diff --no-color --no-ext-diff --binary -- 'old' 'new'; } 2>/dev/null | cksum")
    }

    @Test("Lee las huellas en orden e ignora el ruido del perfil")
    func parse() {
        #expect(GitFingerprint.parse("Bienvenido\nARGOS_FP:123 45\nARGOS_FP:4294967295 0\n") == ["123 45", "4294967295 0"])
    }

    @Test("La huella de un archivo sin seguimiento cambia con su contenido (sh real)")
    func untrackedRuns() throws {
        let root = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(root) }
        let change = GitFileChange(path: "n.txt", originalPath: nil, indexCode: "?", worktreeCode: "?")
        let command = try #require(GitFingerprint.commands(root: root.path, changes: [change], hasCommits: true).first)
        try Data("uno".utf8).write(to: root.appendingPathComponent("n.txt"))
        let first = GitFingerprint.parse(try LocalShell.run(command, home: root).stdout)
        try Data("dos".utf8).write(to: root.appendingPathComponent("n.txt"))
        let second = GitFingerprint.parse(try LocalShell.run(command, home: root).stdout)
        #expect(first == [PosixChecksum.fingerprint(of: Data("uno".utf8))])
        #expect(second.count == 1 && second != first)
    }
}

@Suite("GitChangesModel: diff al día y commit revisado")
struct GitChangesFreshnessTests {

    private static let modified = GitFileChange(path: "a.txt", originalPath: nil, indexCode: " ", worktreeCode: "M")
    private static let other = GitFileChange(path: "b.txt", originalPath: nil, indexCode: " ", worktreeCode: "M")

    private static func status(_ changes: [GitFileChange]) -> GitStatusResult {
        .repository(GitRepositoryStatus(
            root: "/r",
            branch: GitBranchInfo(name: "main", upstream: "origin/main", ahead: 0, behind: 0, hasCommits: true, upstreamGone: false),
            changes: changes, truncated: false
        ))
    }

    @Test("El sondeo recarga el diff si el archivo cambió aunque su estado git sea el mismo")
    @MainActor func pollReloadsStaleDiff() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        await model.select("a.txt")
        await model.refresh(reloadDiff: false)
        #expect(mock.diffRequests.count == 1)
        mock.gitFingerprintByPath["a.txt"] = "otra"
        await model.refresh(reloadDiff: false)
        #expect(mock.diffRequests.count == 2)
        await model.refresh(reloadDiff: false)
        #expect(mock.diffRequests.count == 2)
    }

    @Test("Volver a pulsar el archivo seleccionado recarga su diff")
    @MainActor func reselectReloads() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        await model.select("a.txt")
        await model.select("a.txt")
        #expect(mock.diffRequests.count == 2)
        await model.select(nil)
        await model.select(nil)
        #expect(model.diffState == .none)
    }

    @Test("Si un diff revisado cambió antes del commit, pide confirmación y no commitea")
    @MainActor func commitAsksWhenReviewedDiffChanged() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        await model.select("a.txt")
        model.commitMessage = "fix: algo"
        mock.gitFingerprintByPath["a.txt"] = "editado por Claude"
        await model.commit()
        #expect(mock.commits.isEmpty)
        #expect(model.commitReview?.contains("a.txt") == true)
        await model.confirmCommit()
        #expect(mock.commits.count == 1)
        #expect(model.commitReview == nil)
    }

    @Test("Si aparece un archivo nuevo antes del commit, pide confirmación; cancelar no commitea")
    @MainActor func commitAsksWhenFilesChanged() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        model.commitMessage = "fix"
        mock.gitStatusResult = Self.status([Self.modified, Self.other])
        await model.commit()
        #expect(mock.commits.isEmpty)
        #expect(model.commitReview?.contains("1 archivo nuevo") == true)
        model.cancelCommit()
        #expect(model.commitReview == nil)
        #expect(model.commitMessage == "fix")
    }

    @Test("Sin cambios desde que se vio, el commit va directo")
    @MainActor func commitWithoutChanges() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        await model.select("a.txt")
        model.commitMessage = "fix"
        await model.commit()
        #expect(model.commitReview == nil)
        #expect(mock.commits.count == 1)
    }

    @Test("Texto del aviso")
    func reviewMessage() {
        #expect(GitChangesModel.commitReviewMessage(shown: [Self.modified], current: [Self.modified], changedDiffs: []) == nil)
        let message = GitChangesModel.commitReviewMessage(shown: [Self.modified, Self.other], current: [Self.modified], changedDiffs: ["dir/a.txt"])
        #expect(message == "Desde que miraste los cambios, 1 archivo ya no tiene cambios; cambió el contenido de a.txt desde que lo revisaste. "
                + "Revisa la lista antes de hacer el commit o hazlo igualmente.")
    }
}
