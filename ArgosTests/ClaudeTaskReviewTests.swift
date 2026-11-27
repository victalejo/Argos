//
//  ClaudeTaskReviewTests.swift
//  ArgosTests
//
//  Revisor automático antes del push (lógica pura): el informe, el listado y el sondeo
//  con lo que trae el servidor (que no es de fiar), el encargo de arreglo, la pantalla y
//  la bandeja.
//

import Testing
import Foundation
@testable import Argos

@Suite("Revisor antes del push (lectura)")
struct ClaudeTaskReviewParsingTests {

    @Test func leeElInformeConTolerancia() throws {
        let review = try #require(ClaudeTaskReview.parse("""
            {"verdict":"block","summary":"  Secreto  ","findings":[
              {"severity":"LOW","category":"other","message":"menor"},
              {"severity":"critical","category":"secrets","file":"a.swift","line":"7","message":"token"},
              {"severity":"rarísima","message":"sin severidad"},
              {"severity":"high","message":""},
              "no es un objeto"
            ]}
            """))
        #expect(review.verdict == .block && review.summary == "Secreto")
        #expect(review.findings.count == 3, "sin mensaje o sin forma de objeto se descartan")
        #expect(review.sortedFindings.first?.severity == .critical)
        #expect(review.sortedFindings.first?.location == "a.swift:7")
        #expect(review.findings.contains { $0.severity == nil })
        #expect(review.causeText == nil)

        let inconclusive = try #require(ClaudeTaskReview.parse(#"{"verdict":"inconclusive","cause":"timeout","findings":[]}"#))
        #expect(inconclusive.causeText == String(localized: "El revisor no respondió a tiempo."))
        #expect(ClaudeTaskReview.parse("no es json") == nil)
        #expect(ClaudeTaskReview.parse("[1,2]") == nil)

        let many = "{\"verdict\":\"block\",\"findings\":[" + Array(repeating: #"{"message":"x"}"#, count: 80).joined(separator: ",") + "]}"
        #expect(ClaudeTaskReview.parse(many)?.findings.count == ClaudeTaskReview.maxFindings)
    }

    @Test func elListadoTraeElInformeYLoNecesarioParaArreglar() {
        let output = """
            @@task -srv-app/000003-ccc
            state paused
            reason review
            review {"verdict":"block","summary":"Mal","findings":[{"severity":"high","message":"borra tests"}]}
            meta title=Arregla
            meta target=agent
            meta agent=11111111-2222-4333-8444-555555555555
            meta branch=argos/encargo-ccc
            meta dir=/srv/app-encargo-ccc
            meta push=1
            meta check=npm test
            meta max_minutes=30
            meta estado_futuro=desconocido
            prompt Arregla
            @@task -srv-app/000004-ddd
            state done
            reason\u{20}
            reviewed approve
            prompt otro
            @@task -srv-app/000005-eee
            state paused
            reason review-dentro-de-un-año
            prompt raro
            """
        let tasks = ClaudeTask.parse(listOutput: output)
        #expect(tasks.count == 3)
        let blocked = tasks[0]
        #expect(blocked.isBlockedByReview && blocked.push)
        #expect(blocked.review?.findings.first?.severity == .high)
        #expect(blocked.directory == "/srv/app-encargo-ccc" && blocked.checkCommand == "npm test" && blocked.maxMinutes == 30)
        #expect(tasks[1].reviewedVerdict == "approve" && tasks[1].review == nil)
        #expect(tasks[2].reason == nil && !tasks[2].isBlockedByReview, "motivos desconocidos se toleran")
    }

    @Test func elSondeoTraeLosBloqueadosYDescartaRutasRaras() {
        let lines = ["-srv-app/000003-ccc|Arregla el login", "../etc/000001-x|malo", "-srv-app/000004-d", "basura"]
        let blocks = ClaudeTaskReviewBlock.parse(lines: lines)
        #expect(blocks.map(\.id) == ["-srv-app/000003-ccc", "-srv-app/000004-d"])
        #expect(blocks.first?.title == "Arregla el login")

        let output = """
            @@argos-poll:reviews
            -srv-app/000003-ccc|Arregla
            @@argos-poll:end
            """
        let parsed = WorkspacePollCommand.parse(output, requested: [.reviews])
        #expect(parsed.reviewBlocks?.map(\.folder) == ["000003-ccc"])
        #expect(WorkspacePollCommand.parse("@@argos-poll:reviews\n-x/000001-a|b", requested: [.reviews]).reviewBlocks == nil,
                "a medias: sin dato")
        #expect(WorkspacePollCommand.script(for: [.reviews]).contains("review-inconclusive"))
    }
}

@Suite("Revisor antes del push (arreglo)")
struct ClaudeTaskReviewFixTests {

    static func blocked(agent: Bool) -> ClaudeTask {
        let target = agent
            ? "meta target=agent\nmeta agent=11111111-2222-4333-8444-555555555555\nmeta branch=argos/encargo-ccc\nmeta dir=/srv/app-encargo-ccc"
            : "meta target=terminal\nmeta session=app\nmeta window=2\nmeta dir=/srv/app"
        return ClaudeTask.parse(listOutput: """
            @@task -srv-app/000003-ccc
            state paused
            reason review
            review {"verdict":"block","summary":"Hay un secreto","findings":[{"severity":"low","message":"menor"},{"severity":"critical","category":"secrets","file":"a.env","message":"token"}]}
            meta title=Sube la config
            \(target)
            meta push=1
            meta check=make test
            prompt Sube la config
            """)[0]
    }

    @Test func enAgenteReusaSuWorktreeYRama() throws {
        let request = try #require(ClaudeTaskReviewFix.request(for: Self.blocked(agent: true), permissionMode: .acceptEdits))
        guard case .agent(let id, let worktree, let branch) = request.target else { Issue.record("no es agente"); return }
        #expect(PersistentAgentScript.isValidID(id) && id != "11111111-2222-4333-8444-555555555555", "agente nuevo")
        #expect(worktree == "/srv/app-encargo-ccc" && branch == "argos/encargo-ccc")
        #expect(request.reuseWorktree && request.commit && request.push && request.permissionMode == .acceptEdits)
        let meta = request.metaText(directory: "/srv/app")
        #expect(meta.contains("fixes=000003-ccc\n") && meta.contains("check=make test\n") && meta.contains("source=review\n"))
        #expect(meta.contains("dir=/srv/app-encargo-ccc\n"))
        // Lo más grave primero, con su archivo.
        let critical = try #require(request.prompt.range(of: "critical [secrets] (a.env): token"))
        let low = try #require(request.prompt.range(of: "low: menor"))
        #expect(critical.lowerBound < low.lowerBound)
        #expect(request.prompt.contains("No hagas commit ni push"))

        let scripts = try ClaudeTaskAgentScripts.make(
            request: request, agentID: id, worktree: worktree, branch: branch,
            projectPath: "/srv/app", claudePath: "/usr/local/bin/claude"
        )
        #expect(!scripts.launch.contains("worktree add"), "no crea otro worktree")
        #expect(scripts.launch.contains("[ -d '/srv/app-encargo-ccc' ]"))
    }

    @Test func enTerminalVaASuVentana() throws {
        let request = try #require(ClaudeTaskReviewFix.request(for: Self.blocked(agent: false), permissionMode: .default))
        #expect(request.target == .terminal && request.session == "app" && request.window == 2)
        #expect(request.metaText(directory: "/srv/app").contains("fixes=000003-ccc\n"))
    }

    @Test func sinCarpetaNoSeSabeDondeArreglar() {
        let task = ClaudeTask.parse(listOutput: "@@task -srv-app/000003-ccc\nstate paused\nreason review\nmeta target=agent\n")[0]
        #expect(ClaudeTaskReviewFix.request(for: task, permissionMode: .default) == nil)
    }

    @Test func noConcluyentePideRevisarLaRama() {
        let task = ClaudeTask.parse(listOutput: """
            @@task -srv-app/000003-ccc
            state paused
            reason review-inconclusive
            review {"verdict":"inconclusive","cause":"invalid","findings":[]}
            meta session=app
            """)[0]
        #expect(task.isBlockedByReview)
        #expect(ClaudeTaskReviewFix.prompt(for: task).contains("no fue concluyente"))
    }

    @Test func lasClavesExtraDelMetaSonSeguras() {
        var request = ClaudeTaskRequest(prompt: "x", session: "s", window: 0)
        request.extraMeta = ["fixes": "a\nb", "mal=clave": "x", "": "y"]
        let meta = request.metaText(directory: "/d")
        #expect(meta.contains("fixes=a b\n"))
        #expect(!meta.contains("mal=clave") && !meta.contains("\n=y"))
    }
}

@MainActor
@Suite("Revisor antes del push (pantalla y bandeja)")
struct ClaudeTaskReviewModelTests {

    private static let project = Project(name: "App", path: "/srv/app")

    @Test func laPantallaSubeIgualmenteOPideElArreglo() async {
        let mock = MockSSHService()
        mock.tasks = [ClaudeTaskReviewFixTests.blocked(agent: true)]
        let model = ClaudeTasksModel(service: mock, serverID: UUID(), project: Self.project, claudeWindows: [:])
        await model.reload()
        let task = model.openTasks[0]
        await model.pushAnyway(task)
        #expect(mock.taskActions == ["push-anyway 000003-ccc"])
        await model.requestFix(task)
        #expect(mock.enqueuedTasks.count == 1)
        #expect(mock.enqueuedTasks.first?.0.extraMeta["fixes"] == "000003-ccc")
        #expect(mock.enqueuedTasks.first?.1 == "/srv/app")
        #expect(model.errorMessage == nil)

        // Lo que no está bloqueado no se toca.
        let done = ClaudeTask.parse(listOutput: "@@task -srv-app/000001-a\nstate done\n")[0]
        await model.pushAnyway(done)
        #expect(mock.taskActions.count == 1)
        #expect(model.errorMessage == ClaudeTaskReviewError.notBlocked.errorDescription)
    }

    @Test func laBandejaLoEnsenaConSuProyecto() {
        let server = UUID()
        let block = ClaudeTaskReviewBlock(projectKey: ClaudeUsageProjects.key(forPath: Self.project.path), folder: "000003-ccc", title: "Sube la config")
        let items = AttentionList.build(
            inbox: AttentionInbox(),
            servers: [.init(serverID: server, claude: .empty, projects: [Self.project])],
            reviews: [.init(serverID: server, block: block)]
        )
        let item = try? #require(items.first)
        #expect(item?.kind == .reviewBlocked && item?.needsResponse == true)
        #expect(item?.title == "App")
        #expect(item?.destination == .taskReview(serverID: server, block: block, session: Self.project.sessionName))
    }
}
