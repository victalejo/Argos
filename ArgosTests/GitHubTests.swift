//
//  GitHubTests.swift
//  ArgosTests
//
//  GitHub con el `gh` del servidor: parser de la salida (JSON reales de gh 2.103),
//  comandos (entrecomillado, sin prompts), validación del clonado, vigilante de CI y
//  `GitHubStatusModel` con el mock.
//

import Foundation
import Testing
@testable import Argos

// MARK: - Parser

@Suite("GitHubParser")
struct GitHubParserTests {

    static let sha = "7ac4b42277493bf9bc91d1f90806912228f602e1"

    static let prJSON = """
    {"isDraft":false,"number":3,"reviewDecision":"CHANGES_REQUESTED","state":"OPEN",\
    "statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/1/job/2",\
    "name":"build","status":"COMPLETED","workflowName":"Android"},{"__typename":"CheckRun","conclusion":"",\
    "detailsUrl":"https://github.com/o/r/actions/runs/3/job/4","name":"test","status":"IN_PROGRESS","workflowName":"CI"},\
    {"__typename":"StatusContext","context":"ci/externo","state":"FAILURE","targetUrl":"https://ci.example.com/9"}],\
    "title":"fix(terminal): forzar UTF-8","url":"https://github.com/o/r/pull/3"}
    """

    static let runsJSON = """
    [{"conclusion":"","createdAt":"2026-11-10T16:19:27Z","databaseId":11,"displayTitle":"feat: x","event":"push",\
    "headSha":"\(sha)","status":"in_progress","url":"https://github.com/o/r/actions/runs/11","workflowName":"CI"},\
    {"conclusion":"failure","createdAt":"2026-11-10T16:00:00Z","databaseId":10,"displayTitle":"feat: x","event":"push",\
    "headSha":"\(sha)","status":"completed","url":"https://github.com/o/r/actions/runs/10","workflowName":"CI"},\
    {"conclusion":"success","createdAt":"2026-11-10T16:19:27Z","databaseId":12,"displayTitle":"feat: x","event":"push",\
    "headSha":"\(sha)","status":"completed","url":"https://github.com/o/r/actions/runs/12","workflowName":"Android"}]
    """

    private func output(pr: String?, runs: String?, branch: String = "main") -> String {
        var lines = ["motd del servidor", "ARGOS_GH:sha \(Self.sha)", "ARGOS_GH:branch \(branch)"]
        if let pr { lines.append("ARGOS_GH:pr \(pr) ") }
        if let runs { lines.append("ARGOS_GH:runs \(runs) ") }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("PR con checks de Actions y de estado externo; CI por workflow (la última ejecución)")
    func parsesSnapshot() throws {
        guard case .loaded(let snapshot) = GitHubParser.parseStatus(output(pr: Self.prJSON, runs: Self.runsJSON)) else {
            Issue.record("Esperaba datos"); return
        }
        #expect(snapshot.shortSha == "7ac4b42")
        #expect(snapshot.branch == "main")
        let pr = try #require(snapshot.pullRequest)
        #expect(pr.number == 3)
        #expect(pr.state == .open)
        #expect(pr.review == .changesRequested)
        #expect(pr.reviewLabel == "Piden cambios")
        #expect(pr.checks.map(\.state) == [.success, .pending, .failure])
        #expect(pr.checks[2].title == "ci/externo")
        #expect(pr.checksState == .failure)
        #expect(snapshot.runs.map(\.workflow) == ["Android", "CI"])
        #expect(snapshot.runs.map(\.id) == [12, 11])
        #expect(snapshot.ciState == .pending)
        #expect(snapshot.warning == nil)
    }

    @Test("Sin PR para la rama: solo el CI")
    func noPullRequest() {
        let result = GitHubParser.parseStatus(output(pr: "no pull requests found for branch \"main\"", runs: "[]"))
        guard case .loaded(let snapshot) = result else { Issue.record("Esperaba datos"); return }
        #expect(snapshot.pullRequest == nil)
        #expect(snapshot.runs.isEmpty)
        #expect(snapshot.ciState == nil)
    }

    @Test("gh ausente, sin sesión, sin remoto de GitHub o fuera de un repo")
    func states() {
        #expect(GitHubParser.parseStatus("ARGOS_GH:missing\n") == .ghMissing)
        #expect(GitHubParser.parseStatus("ARGOS_GH:sha \nARGOS_GH:branch \n") == .notGitHub)
        #expect(GitHubParser.parseStatus(output(
            pr: "To get started with GitHub CLI, please run:  gh auth login", runs: nil)) == .notAuthenticated)
        #expect(GitHubParser.parseStatus(output(
            pr: "none of the git remotes configured for this repository point to a known GitHub host.", runs: nil)) == .notGitHub)
    }

    @Test("Si todo falla es un error; si falla una parte, aviso con lo demás")
    func failures() {
        let both = GitHubParser.parseStatus(output(pr: "HTTP 502: Bad Gateway", runs: "HTTP 502: Bad Gateway"))
        #expect(both == .failed("HTTP 502: Bad Gateway"))
        guard case .loaded(let partial) = GitHubParser.parseStatus(output(pr: Self.prJSON, runs: "HTTP 502")) else {
            Issue.record("Esperaba datos parciales"); return
        }
        #expect(partial.pullRequest?.number == 3)
        #expect(partial.warning == "HTTP 502")
    }

    @Test("Estados de Actions y de commits")
    func checkStates() {
        #expect(GitHubCheckState.from(status: "queued", conclusion: nil) == .pending)
        #expect(GitHubCheckState.from(status: "completed", conclusion: "timed_out") == .failure)
        #expect(GitHubCheckState.from(status: "COMPLETED", conclusion: "NEUTRAL") == .success)
        #expect(GitHubCheckState.from(status: "completed", conclusion: "cancelled") == .cancelled)
        #expect(GitHubCheckState.from(contextState: "PENDING") == .pending)
        #expect(GitHubCheckState.aggregate([.skipped, .success]) == .success)
        #expect(GitHubCheckState.aggregate([.skipped]) == .skipped)
        #expect(GitHubCheckState.aggregate([.success, .pending, .failure]) == .failure)
        #expect(GitHubCheckState.aggregate([]) == nil)
    }

    @Test("Repositorios, URL del PR creado y salida del clonado")
    func operations() {
        let repos = GitHubParser.parseRepositories("""
        ARGOS_GH:repos [{"description":"","isPrivate":true,"nameWithOwner":"victalejo/roomies","updatedAt":"2026-11-09T03:04:53Z"}]
        """)
        guard case .loaded(let list) = repos else { Issue.record("Esperaba repos"); return }
        #expect(list.map(\.name) == ["roomies"])
        #expect(list.first?.isPrivate == true)
        #expect(GitHubParser.parseRepositories("ARGOS_GH:missing") == .ghMissing)
        #expect(GitHubParser.createdPullRequestURL("Creating pull request…\nhttps://github.com/o/r/pull/8\n")
                == URL(string: "https://github.com/o/r/pull/8"))
        #expect(GitHubParser.clonedPath("Cloning…\nARGOS_GH:path /srv/app\n") == "/srv/app")
        #expect(GitHubParser.cloneRefusal("ARGOS_GH:exists") != nil)
        #expect(GitHubParser.cloneRefusal("ARGOS_GH:path /x") == nil)
    }
}

// MARK: - Comandos

@Suite("GitHubCommands")
struct GitHubCommandsTests {

    @Test("El estado corre bajo sh, sin prompts y con la raíz entrecomillada")
    func status() {
        let command = GitHubCommands.status(root: "/srv/a'b; rm -rf ~")
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.contains("GH_PROMPT_DISABLED=1"))
        #expect(command.contains("gh pr view"))
        #expect(command.contains("gh run list --commit"))
        #expect(!command.contains("cd /srv/a'b"))
    }

    @Test("Crear PR y relanzar")
    func operations() {
        #expect(GitHubCommands.createPullRequest(root: "/r", draft: true).contains("gh pr create --fill --draft"))
        #expect(!GitHubCommands.createPullRequest(root: "/r", draft: false).contains("--draft"))
        #expect(GitHubCommands.rerunFailed(root: "/r", runID: 42).contains("gh run rerun 42 --failed"))
    }

    @Test("Clonar expande ~ y entrecomilla repo y carpeta")
    func clone() throws {
        let request = try GitHubCloneRequest.make(repository: "o/r", parent: "~/proy", folder: "a b")
        let command = GitHubCommands.clone(request)
        #expect(command.contains(#"p="$HOME"/"#))
        #expect(command.contains("gh repo clone"))
        #expect(command.contains("ARGOS_GH:exists"))
    }

    @Test("Validación del clonado", arguments: [
        ("o/r", true), ("victalejo/Argos.git", true), ("https://github.com/o/r", true), ("git@github.com:o/r.git", true),
        ("-o/r", false), ("o/-r", false), ("o", false), ("o/r/x", false), ("o/r;rm", false), ("../x", false), ("https://a b", false),
    ])
    func validation(repository: String, valid: Bool) {
        #expect(GitHubCloneRequest.isValidRepository(repository) == valid)
    }

    @Test("Carpeta por defecto y carpetas no válidas")
    func folders() {
        #expect(GitHubCloneRequest.defaultFolder(for: "o/app.git") == "app")
        #expect(GitHubCloneRequest.defaultFolder(for: "https://github.com/o/app/") == "app")
        #expect(GitHubCloneRequest.defaultFolder(for: "git@github.com:o/app.git") == "app")
        #expect(throws: GitHubCloneRequest.ValidationError.invalidFolder) {
            try GitHubCloneRequest.make(repository: "o/r", parent: "/srv", folder: "a/b")
        }
        #expect(throws: GitHubCloneRequest.ValidationError.missingParent) {
            try GitHubCloneRequest.make(repository: "o/r", parent: " ", folder: "r")
        }
    }
}

// MARK: - Vigilante de CI

@Suite("CIWatcher")
struct CIWatcherTests {

    private static func snapshot(sha: String = "abc", _ states: [(String, GitHubCheckState)]) -> GitHubStatusResult {
        .loaded(GitHubSnapshot(
            headSha: sha, branch: "main", pullRequest: nil,
            runs: states.enumerated().map { index, item in
                GitHubRun(id: index, workflow: item.0, title: "", state: item.1, url: nil, event: "push", createdAt: nil)
            },
            warning: nil
        ))
    }

    @Test("Tras un push fija el commit y avisa una vez cuando todo termina")
    func finishes() {
        var watcher = CIWatcher()
        let start = Date()
        watcher.watch(root: "/r", name: "app", sha: nil, now: start)
        #expect(watcher.isDue(now: start))
        #expect(watcher.apply(Self.snapshot([("CI", .pending)]), root: "/r", now: start) == nil)
        #expect(watcher.watches["/r"]?.sha == "abc")
        // Un workflow falló pero otro sigue: aún no se avisa.
        #expect(watcher.apply(Self.snapshot([("CI", .failure), ("Android", .pending)]), root: "/r", now: start + 30) == nil)
        let done = watcher.apply(Self.snapshot([("CI", .failure), ("Android", .success)]), root: "/r", now: start + 60)
        #expect(done?.state == .failure)
        #expect(done?.failed == ["CI"])
        #expect(done?.title == "CI de «app»: falló")
        #expect(watcher.isEmpty)
    }

    @Test("Sin ejecuciones durante un rato, se deja; un fallo de red se reintenta")
    func givesUp() {
        var watcher = CIWatcher()
        let start = Date()
        watcher.watch(root: "/r", name: "app", sha: "abc", now: start)
        #expect(watcher.apply(.failed("red"), root: "/r", now: start) == nil)
        #expect(!watcher.isEmpty)
        #expect(watcher.apply(Self.snapshot([]), root: "/r", now: start + 10) == nil)
        #expect(!watcher.isEmpty)
        #expect(watcher.apply(Self.snapshot([]), root: "/r", now: start + CIWatcher.noRunsGiveUp + 1) == nil)
        #expect(watcher.isEmpty)
    }

    @Test("Otro commit encima o sin GitHub: deja de vigilar")
    func dropsOnChange() {
        var watcher = CIWatcher()
        let now = Date()
        watcher.watch(root: "/r", name: "app", sha: "abc", now: now)
        _ = watcher.apply(Self.snapshot(sha: "def", [("CI", .pending)]), root: "/r", now: now)
        #expect(watcher.isEmpty)
        watcher.watch(root: "/r", name: "app", sha: "abc", now: now)
        _ = watcher.apply(.notGitHub, root: "/r", now: now)
        #expect(watcher.isEmpty)
    }

    @Test("Repetir la vigilancia no reinicia la espera; el panel completa el commit de un push")
    func idempotent() {
        var watcher = CIWatcher()
        let start = Date()
        watcher.watch(root: "/r", name: "app", sha: nil, now: start)
        watcher.watch(root: "/r", name: "otro", sha: "abc", now: start + 50)
        #expect(watcher.watches["/r"]?.sha == "abc")
        #expect(watcher.watches["/r"]?.since == start)
        watcher.watch(root: "/r", name: "app", sha: "abc", now: start + 90)
        #expect(watcher.watches["/r"]?.since == start)
        watcher.markPolled(now: start)
        #expect(!watcher.isDue(now: start + 5))
        #expect(watcher.isDue(now: start + CIWatcher.pollInterval))
    }
}

// MARK: - Modelos con el mock

@MainActor
@Suite("GitHubStatusModel")
struct GitHubStatusModelTests {

    private static let pending = GitHubStatusResult.loaded(GitHubSnapshot(
        headSha: "abc", branch: "main", pullRequest: nil,
        runs: [GitHubRun(id: 5, workflow: "CI", title: "", state: .failure, url: nil, event: "push", createdAt: nil),
               GitHubRun(id: 6, workflow: "Android", title: "", state: .pending, url: nil, event: "push", createdAt: nil)],
        warning: nil
    ))

    private static let branch = GitBranchInfo(name: "main", upstream: "origin/main", ahead: 0, behind: 0,
                                              hasCommits: true, upstreamGone: false)

    @Test("Espacia las lecturas y avisa del CI en curso")
    func throttlesAndReportsPending() async {
        let mock = MockSSHService()
        mock.gitHubStatusResult = Self.pending
        var pending: [String] = []
        let model = GitHubStatusModel(root: "/r", service: mock) { _, sha in pending.append(sha) }
        let start = Date()
        await model.refresh(now: start)
        await model.refresh(now: start + 5)
        #expect(mock.gitHubStatusRequests.count == 1)
        #expect(model.currentInterval == GitHubStatusModel.pendingInterval)
        await model.refresh(now: start + GitHubStatusModel.pendingInterval)
        #expect(mock.gitHubStatusRequests.count == 2)
        #expect(pending == ["abc", "abc"])
    }

    @Test("Crear PR solo con la rama subida y sin PR; relanzar refresca")
    func operations() async {
        let mock = MockSSHService()
        mock.gitHubStatusResult = Self.pending
        let model = GitHubStatusModel(root: "/r", service: mock)
        await model.refresh(force: true)
        #expect(model.canCreatePullRequest(branch: Self.branch))
        let ahead = GitBranchInfo(name: "main", upstream: "origin/main", ahead: 1, behind: 0, hasCommits: true, upstreamGone: false)
        #expect(!model.canCreatePullRequest(branch: ahead))
        await model.createPullRequest(draft: true)
        #expect(mock.createdPullRequests.first?.draft == true)
        #expect(model.notice == "PR creado: https://github.com/o/r/pull/7")
        guard let failed = model.snapshot?.failedRuns.first else { Issue.record("Sin fallidos"); return }
        await model.rerunFailed(failed)
        #expect(mock.rerunRequests == [5])
        #expect(mock.gitHubStatusRequests.count == 3)
    }

    @Test("Un fallo con datos visibles no los borra")
    func keepsDataOnFailure() async {
        let mock = MockSSHService()
        mock.gitHubStatusResult = Self.pending
        let model = GitHubStatusModel(root: "/r", service: mock)
        await model.refresh(force: true)
        mock.gitHubStatusResult = .failed("HTTP 502")
        await model.refresh(force: true)
        #expect(model.snapshot != nil)
    }
}

@MainActor
@Suite("SessionsViewModel: CI vigilado")
struct SessionsViewModelCITests {

    @Test("Avisa al terminar el CI de lo subido y deja de vigilarlo")
    func pollsWatches() async {
        let mock = MockSSHService()
        mock.storedProjects = [Project(name: "app", path: "/srv/app")]
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        let start = Date()
        vm.watchCI(root: "/srv/app", now: start)
        mock.gitHubStatusResult = .loaded(GitHubSnapshot(
            headSha: "abc", branch: "main", pullRequest: nil,
            runs: [GitHubRun(id: 1, workflow: "CI", title: "", state: .success, url: nil, event: "push", createdAt: nil)],
            warning: nil
        ))
        let results = await vm.pollCIWatches(now: start)
        #expect(results.map(\.title) == ["CI de «app»: pasó"])
        #expect(vm.ciWatcher.isEmpty)
        #expect(await vm.pollCIWatches(now: start + 60).isEmpty)
        #expect(mock.gitHubStatusRequests == ["/srv/app"])
    }

    @Test("El push del panel empieza a vigilar el CI")
    func pushStartsWatch() async {
        let mock = MockSSHService()
        mock.gitStatusResult = .repository(GitRepositoryStatus(
            root: "/srv/app",
            branch: GitBranchInfo(name: "main", upstream: "origin/main", ahead: 2, behind: 0, hasCommits: true, upstreamGone: false),
            changes: [], truncated: false
        ))
        let vm = SessionsViewModel(service: mock)
        let model = GitChangesModel(path: "/srv/app", service: mock) { vm.watchCI(root: $0) }
        await model.refresh()
        await model.push()
        #expect(vm.ciWatcher.watches["/srv/app"] != nil)
    }
}

@MainActor
@Suite("GitHubCloneModel")
struct GitHubCloneModelTests {

    @Test("La carpeta sigue al repositorio hasta que el usuario la cambia")
    func folderFollowsRepository() {
        let model = GitHubCloneModel(service: MockSSHService())
        model.repository = "victalejo/argos.git"
        #expect(model.folder == "argos")
        #expect(model.destination == "~/argos")
        model.folder = "mio"
        model.repository = "o/otro"
        #expect(model.folder == "mio")
        model.choose(GitHubRepository(nameWithOwner: "o/elegido", description: "", isPrivate: false, updatedAt: nil))
        #expect(model.folder == "elegido")
    }

    @Test("Valida antes de clonar y clona con la petición normalizada")
    func clones() async throws {
        let mock = MockSSHService()
        let model = GitHubCloneModel(service: mock)
        model.repository = "-x/y"
        #expect(!model.canClone)
        model.repository = " o/app "
        model.parent = "/srv"
        #expect(model.canClone)
        let path = try await model.clone()
        #expect(path == "/srv/clonado")
        #expect(mock.cloneRequests == [GitHubCloneRequest(repository: "o/app", parent: "/srv", folder: "app")])
        #expect(!model.isCloning)
    }

    @Test("Repositorios más recientes primero; carga una sola vez")
    func repositories() async {
        let mock = MockSSHService()
        let old = GitHubRepository(nameWithOwner: "o/viejo", description: "", isPrivate: false, updatedAt: Date(timeIntervalSince1970: 1))
        let new = GitHubRepository(nameWithOwner: "o/nuevo", description: "", isPrivate: true, updatedAt: Date(timeIntervalSince1970: 9))
        mock.gitHubRepositoriesResult = .loaded([old, new])
        let model = GitHubCloneModel(service: mock)
        await model.loadRepositories()
        #expect(model.repositories == .loaded([new, old]))
        mock.gitHubRepositoriesResult = .notAuthenticated
        await model.loadRepositories()
        #expect(model.repositories == .loaded([new, old]))
        await model.loadRepositories(force: true)
        #expect(model.repositories == .notAuthenticated)
    }
}
