//
//  WorktreeTests.swift
//  ArgosTests
//
//  «Ramas en paralelo»: parser de `git worktree list --porcelain`, validación de ramas y
//  carpetas, comandos, y el ciclo crear/quitar un worktree como proyecto con el mock.
//

import Foundation
import Testing
@testable import Argos

@Suite("GitWorktreeParser")
struct GitWorktreeParserTests {

    static let output = """
    motd
    ARGOS_WT:list
    worktree /srv/app
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /srv/app-worktrees/feat-login
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/feat/login
    locked en uso

    worktree /srv/app-worktrees/viejo
    HEAD 3333333333333333333333333333333333333333
    detached
    prunable gitdir file points to non-existent location

    ARGOS_WT:end
    ARGOS_WT:dirty 0 /srv/app
    ARGOS_WT:dirty 4 /srv/app-worktrees/feat-login
    ARGOS_WT:branch feat/login
    ARGOS_WT:branch fix/x
    ARGOS_WT:branch main
    """

    @Test("Principal, ramas, desacoplado, bloqueado, perdido, cambios y ramas libres")
    func parses() throws {
        guard case .loaded(let listing) = GitWorktreeParser.parseList(Self.output) else {
            Issue.record("Esperaba worktrees"); return
        }
        #expect(listing.worktrees.map(\.path) == ["/srv/app", "/srv/app-worktrees/feat-login", "/srv/app-worktrees/viejo"])
        #expect(listing.worktrees.map(\.isMain) == [true, false, false])
        #expect(listing.worktrees[1].branch == "feat/login")
        #expect(listing.worktrees[1].isLocked)
        #expect(listing.worktrees[1].changedCount == 4)
        #expect(listing.worktrees[2].branch == nil)
        #expect(listing.worktrees[2].displayBranch == "HEAD desacoplado (3333333)")
        #expect(listing.worktrees[2].isPrunable)
        #expect(listing.worktrees[2].changedCount == nil)
        #expect(listing.freeBranches == ["fix/x"])
        #expect(listing.defaultPath(forBranch: "feat/otra") == "/srv/app-worktrees/feat-otra")
    }

    @Test("Repo bare: ningún worktree es el principal")
    func bare() {
        let porcelain = ["worktree /srv/app.git", "bare", "", "worktree /srv/w", "HEAD abc", "branch refs/heads/x"]
        let worktrees = GitWorktreeParser.parsePorcelain(porcelain)
        #expect(worktrees.map(\.path) == ["/srv/w"])
        #expect(worktrees.first?.isMain == false)
    }

    @Test("Sin git, fuera de un repo y salida del alta")
    func states() {
        #expect(GitWorktreeParser.parseList("ARGOS_WT:nogit\n") == .gitMissing)
        #expect(GitWorktreeParser.parseList("ARGOS_WT:norepo\n") == .notRepository)
        #expect(GitWorktreeParser.addedPath("Preparing worktree\nARGOS_WT:path /srv/w x\n") == "/srv/w x")
        #expect(GitWorktreeParser.addRefusal("ARGOS_WT:exists") != nil)
        #expect(GitWorktreeParser.addRefusal("ARGOS_WT:badbranch") != nil)
        #expect(GitWorktreeParser.addRefusal("ARGOS_WT:path /x") == nil)
    }
}

@Suite("GitWorktree: validación y comandos")
struct GitWorktreeRequestTests {

    private static var listing: GitWorktreeListing {
        guard case .loaded(let listing) = GitWorktreeParser.parseList(GitWorktreeParserTests.output) else {
            fatalError("fixture")
        }
        return listing
    }

    @Test("Nombres de rama", arguments: [
        ("feat/login", true), ("fix-1.2", true), ("v1", true),
        ("-x", false), ("a b", false), ("a..b", false), ("a~1", false), ("a^", false), ("a:b", false),
        ("x.lock", false), ("x/", false), ("/x", false), ("a//b", false), ("@", false), ("a@{1}", false),
        (".oculta", false), ("a/.b", false), ("a*", false), ("", false),
    ])
    func branchNames(name: String, valid: Bool) {
        #expect(GitBranchName.isValid(name) == valid)
    }

    @Test("Slugs para carpeta y proyecto")
    func slugs() {
        #expect(GitBranchName.slug("feat/login") == "feat-login")
        #expect(GitBranchName.projectSlug("release/v1.2") == "release-v1-2")
        #expect(SessionsViewModel.worktreeProjectName(parent: Project(name: "app", path: "/srv/app"), branch: "feat/x")
                == "app-feat-x")
    }

    @Test("Rama nueva: no puede existir; existente: debe estar libre; carpeta absoluta")
    func validation() throws {
        let listing = Self.listing
        #expect(throws: GitWorktreeRequest.ValidationError.branchExists) {
            try GitWorktreeRequest.make(listing: listing, branch: "main", createsBranch: true, base: "HEAD", path: "/srv/w")
        }
        #expect(throws: GitWorktreeRequest.ValidationError.branchInUse) {
            try GitWorktreeRequest.make(listing: listing, branch: "feat/login", createsBranch: false, base: "", path: "/srv/w")
        }
        #expect(throws: GitWorktreeRequest.ValidationError.invalidPath) {
            try GitWorktreeRequest.make(listing: listing, branch: "nueva", createsBranch: true, base: "HEAD", path: "srv/w")
        }
        #expect(throws: GitWorktreeRequest.ValidationError.invalidPath) {
            try GitWorktreeRequest.make(listing: listing, branch: "nueva", createsBranch: true, base: "HEAD", path: "/srv/../etc")
        }
        let request = try GitWorktreeRequest.make(listing: listing, branch: " fix/x ", createsBranch: false, base: "", path: "/srv/w")
        #expect(request.branch == "fix/x")
        #expect(request.repository == "/srv/app")
    }

    @Test("Los comandos van bajo sh, entrecomillados, y git revalida la rama")
    func commands() {
        let request = GitWorktreeRequest(repository: "/srv/my app", branch: "feat/x", createsBranch: true,
                                         base: "main", path: "/srv/my app-worktrees/feat-x")
        let add = GitWorktreeCommands.add(request)
        #expect(add.hasPrefix("sh -c '"))
        #expect(add.contains("check-ref-format --branch"))
        #expect(add.contains("worktree add -b"))
        #expect(add.contains("ARGOS_WT:exists"))
        let existing = GitWorktreeRequest(repository: "/r", branch: "fix", createsBranch: false, base: "", path: "/w")
        #expect(!GitWorktreeCommands.add(existing).contains(" -b "))
        #expect(GitWorktreeCommands.remove(repository: "/r", path: "/w", force: true).contains("worktree remove --force"))
        #expect(!GitWorktreeCommands.remove(repository: "/r", path: "/w", force: false).contains("--force"))
        #expect(GitWorktreeCommands.list(path: "/r").contains("GIT_OPTIONAL_LOCKS=0"))
    }
}

@MainActor
@Suite("Worktrees como proyectos")
struct WorktreeProjectsTests {

    private let parent = Project(name: "app", group: "web", path: "/srv/app", startupCommand: "claude")

    private func loaded() async -> (SessionsViewModel, MockSSHService) {
        let mock = MockSSHService()
        mock.storedProjects = [parent]
        mock.worktreeListing = GitWorktreeParser.parseList(GitWorktreeParserTests.output)
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        return (vm, mock)
    }

    @Test("Crear: hereda grupo y comando, guarda la ruta real y arranca su sesión")
    func creates() async throws {
        let (vm, mock) = await loaded()
        mock.addedWorktreePath = "/real/app-worktrees/fix-x"
        let model = WorktreesModel(parent: parent, viewModel: vm)
        await model.load()
        model.createsBranch = false
        model.branch = "fix/x"
        #expect(model.path == "/srv/app-worktrees/fix-x")
        #expect(model.projectName == "app-fix-x")
        let project = try #require(await model.create(defaultStartupCommand: "cc"))
        #expect(mock.addedWorktrees.map(\.branch) == ["fix/x"])
        #expect(project.group == "web")
        #expect(project.startupCommand == "claude")
        #expect(mock.storedProjects.contains { $0.path == "/real/app-worktrees/fix-x" && $0.name == "app-fix-x" })
        #expect(mock.startedProjects.map(\.session).contains("web/app-fix-x"))
        #expect(model.branch.isEmpty)
    }

    @Test("Un nombre repetido se rechaza ANTES de crear el worktree")
    func validatesFirst() async {
        let (vm, mock) = await loaded()
        mock.storedProjects.append(Project(name: "app-nueva", group: "web", path: "/otra"))
        await vm.load()
        let model = WorktreesModel(parent: parent, viewModel: vm)
        await model.load()
        model.branch = "nueva"
        #expect(await model.create(defaultStartupCommand: "cc") == nil)
        #expect(mock.addedWorktrees.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test("La carpeta sigue a la rama hasta que el usuario la cambia")
    func pathFollowsBranch() async {
        let (vm, _) = await loaded()
        let model = WorktreesModel(parent: parent, viewModel: vm)
        await model.load()
        model.branch = "a"
        #expect(model.path == "/srv/app-worktrees/a")
        model.path = "/otra/carpeta"
        model.branch = "b"
        #expect(model.path == "/otra/carpeta")
    }

    @Test("Quitar: detiene la sesión, quita el worktree (forzado si hay cambios) y su proyecto")
    func removes() async throws {
        let (vm, mock) = await loaded()
        let worktreeProject = Project(name: "app-feat-login", group: "web", path: "/srv/app-worktrees/feat-login/")
        mock.storedProjects.append(worktreeProject)
        mock.sessions = [TmuxSession(name: worktreeProject.sessionName, windowCount: 1, isAttached: false, createdAt: Date())]
        await vm.load()
        let model = WorktreesModel(parent: parent, viewModel: vm)
        await model.load()
        let worktree = try #require(model.listing?.worktrees.first { $0.branch == "feat/login" })
        #expect(model.project(for: worktree)?.id == worktreeProject.id)
        await model.remove(worktree, force: true)
        #expect(mock.stoppedSessions == ["web/app-feat-login"])
        #expect(mock.removedWorktrees.map(\.path) == ["/srv/app-worktrees/feat-login"])
        #expect(mock.removedWorktrees.first?.force == true)
        #expect(!mock.storedProjects.contains { $0.id == worktreeProject.id })
    }

    @Test("Abierta desde un worktree, la rama nueva hereda del proyecto principal")
    func namingParent() async {
        let (vm, _) = await loaded()
        let fromWorktree = Project(name: "app-feat-login", group: "web", path: "/srv/app-worktrees/feat-login")
        let model = WorktreesModel(parent: fromWorktree, viewModel: vm)
        await model.load()
        model.branch = "otra"
        #expect(model.projectName == "app-otra")
    }
}
