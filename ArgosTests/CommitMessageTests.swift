//
//  CommitMessageTests.swift
//  ArgosTests
//
//  «Sugerir mensaje» del panel «Cambios»: el script (token por stdin, sin la API, rutas
//  literales y entrecomilladas), la limpieza de la respuesta y el modelo con el mock.
//

import Foundation
import Testing
@testable import Argos

@Suite("CommitMessageSuggestion")
struct CommitMessageSuggestionTests {

    private let changes = [
        GitFileChange(path: "a'b.txt", originalPath: nil, indexCode: " ", worktreeCode: "M"),
        GitFileChange(path: "nuevo.txt", originalPath: nil, indexCode: "?", worktreeCode: "?"),
    ]

    @Test("El token va por stdin, nunca se usa la API y las rutas van literales y entrecomilladas")
    func command() {
        let command = CommitMessageSuggestion.command(claudePath: "/usr/bin/claude", root: "/srv/my app",
                                                      changes: changes, hasCommits: true)
        #expect(command.contains("IFS= read -r ARGOS_OAUTH"))
        #expect(command.contains("env -u ANTHROPIC_API_KEY '/usr/bin/claude' -p --model haiku --output-format text"))
        #expect(command.contains("git --literal-pathspecs -C '/srv/my app'"))
        #expect(command.contains("-M HEAD -- 'a'\\''b.txt'"))
        #expect(command.contains("--no-index -- /dev/null 'nuevo.txt'"))
        #expect(command.contains("log -15 --format=%s"))
        #expect(command.contains("ARGOS_CM_EXIT:"))
        #expect(!command.contains("CLAUDE_CODE_OAUTH_TOKEN=sk"))
    }

    @Test("Sin commits todavía: índice y árbol de trabajo")
    func noCommits() {
        let command = CommitMessageSuggestion.command(claudePath: "/c", root: "/r", changes: [changes[0]], hasCommits: false)
        #expect(command.contains("diff --no-color --no-ext-diff --cached --"))
        #expect(!command.contains("HEAD --"))
    }

    @Test("Limpia bloques de código, comillas y prefijos")
    func clean() {
        #expect(CommitMessageSuggestion.clean("```\nfeat: x\n```") == "feat: x")
        #expect(CommitMessageSuggestion.clean("\"fix: y\"") == "fix: y")
        #expect(CommitMessageSuggestion.clean("Mensaje de commit: docs: z") == "docs: z")
        #expect(CommitMessageSuggestion.clean("feat: x\n\nCuerpo.") == "feat: x\n\nCuerpo.")
    }

    @Test("Código de salida: el mensaje o el error de claude")
    func parse() throws {
        #expect(try CommitMessageSuggestion.parse("feat: x\n\nARGOS_CM_EXIT:0\n") == "feat: x")
        #expect(throws: GitCommandError(message: "Invalid API key · Please run /login")) {
            try CommitMessageSuggestion.parse("Invalid API key · Please run /login\nARGOS_CM_EXIT:1\n")
        }
        #expect(throws: GitCommandError.self) { try CommitMessageSuggestion.parse("cortado a med") }
        #expect(throws: GitCommandError.self) { try CommitMessageSuggestion.parse("\nARGOS_CM_EXIT:0\n") }
    }
}

@MainActor
@Suite("GitChangesModel: mensaje sugerido")
struct SuggestedCommitMessageTests {

    private static let modified = GitFileChange(path: "a.txt", originalPath: nil, indexCode: " ", worktreeCode: "M")
    private static let other = GitFileChange(path: "b.txt", originalPath: nil, indexCode: " ", worktreeCode: "M")

    private func model(_ mock: MockSSHService) async -> GitChangesModel {
        mock.gitStatusResult = .repository(GitRepositoryStatus(
            root: "/r",
            branch: GitBranchInfo(name: "main", upstream: "origin/main", ahead: 0, behind: 0, hasCommits: true, upstreamGone: false),
            changes: [Self.modified, Self.other], truncated: false
        ))
        let model = GitChangesModel(path: "/r", service: mock)
        await model.refresh()
        return model
    }

    @Test("Rellena el mensaje con lo que propone Claude, solo con los archivos marcados, y envía el token")
    func fills() async {
        let mock = MockSSHService()
        mock.agentScript = ["```", "feat: amplía a.txt", "```", "ARGOS_CM_EXIT:0"]
        let model = await model(mock)
        model.setIncluded(false, for: Self.other)
        await model.suggestCommitMessage(oauthToken: "tok")
        #expect(model.commitMessage == "feat: amplía a.txt")
        #expect(model.operation == nil)
        let command = mock.lastAgentCommand ?? ""
        #expect(command.contains("'a.txt'"))
        #expect(!command.contains("'b.txt'"))
        #expect(mock.agentStdinLines.first == "tok")
    }

    @Test("Sin claude en el servidor o con error, avisa y no toca lo escrito")
    func failures() async {
        let mock = MockSSHService()
        let model = await model(mock)
        model.commitMessage = "lo mío"
        mock.claudePath = nil
        await model.suggestCommitMessage(oauthToken: nil)
        #expect(model.errorMessage == "Claude Code no está instalado en el servidor.")
        #expect(model.commitMessage == "lo mío")
        mock.claudePath = "/c"
        mock.agentScript = ["Not logged in · Please run /login", "ARGOS_CM_EXIT:1"]
        await model.suggestCommitMessage(oauthToken: nil)
        #expect(model.errorMessage == "Not logged in · Please run /login")
        #expect(model.commitMessage == "lo mío")
    }

    @Test("Sin archivos marcados no se puede sugerir")
    func needsIncluded() async {
        let model = await model(MockSSHService())
        model.setAllIncluded(false)
        #expect(!model.canSuggestMessage)
    }
}
