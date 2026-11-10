//
//  GitTests.swift
//  ArgosTests
//
//  Panel «Cambios»: parser de `git status --porcelain=v1 -z -b`, parser de diffs,
//  comandos remotos (entrecomillado) y `GitChangesModel` con el mock.
//

import Foundation
import Testing
@testable import Argos

// MARK: - Estado

@Suite("GitStatusParser")
struct GitStatusParserTests {

    private func output(_ porcelain: String, root: String = "/home/dev/app") -> String {
        "motd ruidoso\n\(GitCommands.rootMarker)\(root)\n\(porcelain)"
    }

    @Test("Sin marcador es carpeta sin repositorio")
    func notRepository() {
        #expect(GitStatusParser.parse("") == .notRepository)
        #expect(GitStatusParser.parse("algo del perfil\n") == .notRepository)
    }

    @Test("Detecta git ausente")
    func gitMissing() {
        #expect(GitStatusParser.parse("\(GitCommands.noGitMarker)\n") == .gitMissing)
    }

    @Test("Parsea rama, upstream, ahead/behind y entradas")
    func parsesEntries() throws {
        let porcelain = "## main...origin/main [ahead 2, behind 1]\0 M src/a.swift\0"
            + "A  nuevo.txt\0R  b2.swift\0b.swift\0?? notas/x y.md\0UU conflicto.c\0"
        guard case .repository(let status) = GitStatusParser.parse(output(porcelain)) else {
            Issue.record("Esperaba un repositorio"); return
        }
        #expect(status.root == "/home/dev/app")
        #expect(status.repositoryName == "app")
        #expect(status.branch.name == "main")
        #expect(status.branch.upstream == "origin/main")
        #expect(status.branch.ahead == 2)
        #expect(status.branch.behind == 1)
        #expect(!status.truncated)
        #expect(status.changes.map(\.path) == ["src/a.swift", "nuevo.txt", "b2.swift", "notas/x y.md", "conflicto.c"])
        #expect(status.changes.map(\.kind) == [.modified, .added, .renamed, .untracked, .conflicted])
        #expect(status.changes[2].originalPath == "b.swift")
        #expect(status.changes[2].affectedPaths == ["b.swift", "b2.swift"])
        #expect(status.changes[3].isUntracked)
        #expect(status.changes[4].isConflicted)
    }

    @Test("Repositorio limpio")
    func clean() {
        guard case .repository(let status) = GitStatusParser.parse(output("## main\0")) else {
            Issue.record("Esperaba un repositorio"); return
        }
        #expect(status.isClean)
        #expect(status.branch.upstream == nil)
    }

    @Test("Salida recortada a mitad de entrada")
    func truncatedOutput() {
        guard case .repository(let status) = GitStatusParser.parse(output("## main\0 M a.txt\0 M b.t")) else {
            Issue.record("Esperaba un repositorio"); return
        }
        #expect(status.changes.map(\.path) == ["a.txt"])
        #expect(status.truncated)
    }

    @Test("Cabeceras de rama especiales", arguments: [
        ("No commits yet on main", "main", false, nil as String?, false),
        ("HEAD (no branch)", nil as String?, true, nil, false),
        ("feat/x...origin/feat/x [gone]", "feat/x", true, "origin/feat/x", true),
    ])
    func branchHeaders(header: String, name: String?, hasCommits: Bool, upstream: String?, gone: Bool) {
        let branch = GitStatusParser.parseBranch(header)
        #expect(branch.name == name)
        #expect(branch.hasCommits == hasCommits)
        #expect(branch.upstream == upstream)
        #expect(branch.upstreamGone == gone)
    }
}

// MARK: - Diff

@Suite("GitDiffParser")
struct GitDiffParserTests {

    static let sample = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1,3 +1,4 @@ func main
     uno
    -dos
    +DOS
    +dos y medio
     tres
    \\ No newline at end of file

    """

    @Test("Tipos y números de línea")
    func parsesHunk() {
        let diff = GitDiffParser.parse(Self.sample)
        #expect(diff.lines.map(\.kind) == [.meta, .meta, .meta, .meta, .hunk,
                                           .context, .removed, .added, .added, .context, .noNewline])
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
        #expect(diff.hasContent)
        let removed = diff.lines[6]
        #expect(removed.text == "dos")
        #expect(removed.oldNumber == 2 && removed.newNumber == nil)
        let secondAdded = diff.lines[8]
        #expect(secondAdded.newNumber == 3)
        let lastContext = diff.lines[9]
        #expect(lastContext.oldNumber == 3 && lastContext.newNumber == 4)
    }

    @Test("Detecta binarios")
    func binary() {
        let diff = GitDiffParser.parse("diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n")
        #expect(diff.isBinary)
        #expect(!diff.hasContent)
    }

    @Test("Recortado descarta la última línea a medias")
    func truncated() {
        let diff = GitDiffParser.parse("@@ -1 +1 @@\n+completa\n+a medi", truncated: true)
        #expect(diff.truncated)
        #expect(diff.lines.last?.text == "completa")
    }

    @Test("Inicio de hunk sin recuento")
    func hunkStarts() {
        let first = GitDiffParser.hunkStarts("@@ -0,0 +1 @@")
        #expect(first?.0 == 0 && first?.1 == 1)
        let second = GitDiffParser.hunkStarts("@@ -7 +9,2 @@ x")
        #expect(second?.0 == 7 && second?.1 == 9)
        let broken = GitDiffParser.hunkStarts("@@ roto")
        #expect(broken == nil)
    }
}

// MARK: - Comandos

@Suite("GitCommands")
struct GitCommandsTests {

    private let tricky = GitFileChange(path: "a'; rm -rf ~ #.txt", originalPath: nil,
                                       indexCode: " ", worktreeCode: "M")

    @Test("El estado se ejecuta bajo sh y sin locks")
    func status() {
        let command = GitCommands.status(path: "/srv/my app")
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(command.contains("--porcelain=v1 -z -b"))
    }

    @Test("Las rutas peligrosas van entrecomilladas")
    func quoting() {
        let quoted = ShellQuoting.singleQuoted(tricky.path)
        #expect(quoted == "'a'\\''; rm -rf ~ #.txt'")
        // El script interior lleva la ruta como UN argumento entrecomillado, y el
        // conjunto va entrecomillado otra vez para `sh -c`.
        let discard = GitCommands.discard(root: "/r", change: tricky)
        let inner = "git -C '/r' restore --source=HEAD --staged --worktree -- \(quoted)"
        #expect(discard == ShellQuoting.posixShell(inner))
    }

    @Test("Descartar un archivo nuevo lo limpia")
    func discardUntracked() {
        let change = GitFileChange(path: "n.txt", originalPath: nil, indexCode: "?", worktreeCode: "?")
        #expect(GitCommands.discard(root: "/r", change: change).contains("clean -f --"))
    }

    @Test("Diff según el tipo de archivo")
    func diffVariants() {
        let untracked = GitFileChange(path: "n.txt", originalPath: nil, indexCode: "?", worktreeCode: "?")
        #expect(GitCommands.diff(root: "/r", change: untracked, hasCommits: true).contains("--no-index -- /dev/null"))
        #expect(GitCommands.diff(root: "/r", change: tricky, hasCommits: true).contains("-M HEAD --"))
        #expect(GitCommands.diff(root: "/r", change: tricky, hasCommits: false).contains("--cached"))
    }

    @Test("Push sin upstream publica la rama")
    func push() {
        #expect(GitCommands.push(root: "/r", hasUpstream: false).contains("push -u origin HEAD"))
        #expect(!GitCommands.push(root: "/r", hasUpstream: true).contains("-u origin"))
        #expect(GitCommands.push(root: "/r", hasUpstream: true).contains("GIT_TERMINAL_PROMPT=0"))
    }

    @Test("Commit solo de las rutas elegidas")
    func commit() {
        let changes = [
            GitFileChange(path: "a", originalPath: nil, indexCode: " ", worktreeCode: "M"),
            GitFileChange(path: "b", originalPath: nil, indexCode: "?", worktreeCode: "?"),
        ]
        let command = GitCommands.commitScript(root: "/r", message: "feat: x", changes: changes)
        #expect(command.contains("add -A -- 'a' 'b' &&"))
        #expect(command.contains("commit -m 'feat: x' -- 'a' 'b'"))
    }

    @Test("Un renombrado preparado no pasa su origen a add (git fallaría), sí al commit")
    func commitStagedRename() {
        let renamed = GitFileChange(path: "b2.swift", originalPath: "b.swift", indexCode: "R", worktreeCode: " ")
        let command = GitCommands.commitScript(root: "/r", message: "m", changes: [renamed])
        #expect(command.contains("add -A -- 'b2.swift' &&"))
        #expect(command.contains("commit -m 'm' -- 'b.swift' 'b2.swift'"))
    }

    @Test("El error de git conserva las últimas líneas")
    func errorMessage() {
        let error = GitCommandError.from(stdout: "", stderr: "fatal: Please tell me who you are.\n", exitCode: 128)
        #expect(error.message == "fatal: Please tell me who you are.")
        #expect(GitCommandError.from(stdout: "", stderr: "", exitCode: 1).message.contains("código 1"))
    }
}

// MARK: - Modelo

@MainActor
@Suite("GitChangesModel")
struct GitChangesModelTests {

    private static func status(_ changes: [GitFileChange], upstream: String? = "origin/main", ahead: Int = 0) -> GitStatusResult {
        .repository(GitRepositoryStatus(
            root: "/r",
            branch: GitBranchInfo(name: "main", upstream: upstream, ahead: ahead, behind: 0,
                                  hasCommits: true, upstreamGone: false),
            changes: changes, truncated: false
        ))
    }

    private static let modified = GitFileChange(path: "a.txt", originalPath: nil, indexCode: " ", worktreeCode: "M")
    private static let renamed = GitFileChange(path: "new.txt", originalPath: "old.txt", indexCode: "R", worktreeCode: " ")

    @Test("Commit con rutas incluidas y limpia el mensaje")
    func commitIncluded() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified, Self.renamed])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        #expect(!model.canCommit)
        model.commitMessage = "  fix: algo \n"
        model.setIncluded(false, for: Self.modified)
        #expect(model.includedCount == 1)
        await model.commit()
        #expect(mock.commits.count == 1)
        #expect(mock.commits.first?.message == "fix: algo")
        #expect(mock.commits.first?.paths == ["old.txt", "new.txt"])
        #expect(model.commitMessage.isEmpty)
        #expect(model.notice == "[main abc1234] fix: algo")
    }

    @Test("Un commit fallido conserva el mensaje y muestra el error")
    func commitFails() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        mock.gitError = GitCommandError(message: "fatal: Please tell me who you are.")
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        model.commitMessage = "wip"
        await model.commit()
        #expect(model.commitMessage == "wip")
        #expect(model.errorMessage == "fatal: Please tell me who you are.")
        #expect(model.operation == nil)
    }

    @Test("Seleccionar carga el diff y desaparece si el archivo deja de cambiar")
    func selection() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        mock.gitDiffResult = GitDiffParser.parse(GitDiffParserTests.sample)
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        await model.select("a.txt")
        #expect(model.selectedChange == Self.modified)
        guard case .loaded(let diff) = model.diffState else { Issue.record("Sin diff"); return }
        #expect(diff.additions == 2)

        mock.gitStatusResult = Self.status([])
        await model.refresh(reloadDiff: false)
        #expect(model.selectedPath == nil)
        #expect(model.diffState == .none)
    }

    @Test("El refresco automático no recarga el diff si el archivo no cambió")
    func pollKeepsDiff() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        await model.select("a.txt")
        await model.refresh(reloadDiff: false)
        #expect(mock.diffRequests.count == 1)
        await model.refresh()
        #expect(mock.diffRequests.count == 2)
    }

    @Test("Push solo si hay algo que subir o no hay upstream")
    func pushAvailability() async {
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([], ahead: 0)
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        #expect(!model.canPush)
        mock.gitStatusResult = Self.status([], ahead: 3)
        await model.refresh()
        #expect(model.canPush)
        await model.push()
        #expect(mock.pushes == [true])
        mock.gitStatusResult = Self.status([], upstream: nil)
        await model.refresh()
        #expect(model.canPush)
        #expect(!model.canPull)
    }

    @Test("Descartar llama al servicio y no se permite en conflicto el commit")
    func discardAndConflicts() async {
        let conflict = GitFileChange(path: "c", originalPath: nil, indexCode: "U", worktreeCode: "U")
        let mock = MockSSHService()
        mock.gitStatusResult = Self.status([Self.modified, conflict])
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        model.commitMessage = "x"
        #expect(model.hasConflicts)
        #expect(!model.canCommit)
        await model.discard(Self.modified)
        #expect(mock.discardedChanges == [Self.modified])
    }

    @Test("Estados sin repositorio")
    func states() async {
        let mock = MockSSHService()
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        #expect(model.state == .notRepository)
        mock.gitStatusResult = .gitMissing
        await model.refresh()
        #expect(model.state == .gitMissing)
    }

    @Test("Rutas del commit sin duplicados")
    func commitPaths() {
        let other = GitFileChange(path: "old.txt", originalPath: nil, indexCode: "?", worktreeCode: "?")
        let included = GitChangesModel.includedChanges([Self.renamed, other], excluded: [])
        #expect(GitCommands.commitPaths(included) == ["old.txt", "new.txt"])
        #expect(GitChangesModel.includedChanges([Self.renamed, other], excluded: ["old.txt"]) == [Self.renamed])
    }
}
