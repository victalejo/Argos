//
//  GoldenCatalog+Commands.swift
//  ArgosTests
//
//  Goldens de git, GitHub, worktrees, puertos, hooks de Claude y estado de tmux. Mismas
//  entradas que `GitTest`, `GitHubTest`, `GitWorktreeTest`, `CommitMessageSuggestionTest`,
//  `PortsTest` y `SwiftParityGoldenTest` de Android.
//

import Foundation
@testable import Argos

extension GoldenCatalog {

    static func commands() throws -> [String: String] {
        let root = "/home/u/mi repo's"
        let mod = GitFileChange(path: "src/a b.swift", originalPath: nil, indexCode: " ", worktreeCode: "M")
        let ren = GitFileChange(path: "nuevo.txt", originalPath: "viejo*.txt", indexCode: "R", worktreeCode: " ")
        let unt = GitFileChange(path: "*", originalPath: nil, indexCode: "?", worktreeCode: "?")
        let quotedUntracked = GitFileChange(path: "it's new.txt", originalPath: nil, indexCode: "?", worktreeCode: "?")
        let forwards = [
            ActivePortForward(id: UUID(), remotePort: 5173, targetHost: "localhost", localPort: 5173),
            ActivePortForward(id: UUID(), remotePort: 3000, targetHost: "10.0.0.5", localPort: 3001),
        ]
        return [
            "git-status": GitCommands.status(path: "~/p/$(x)"),
            "git-diff-modified": GitCommands.diff(root: root, change: mod, hasCommits: true),
            "git-diff-renamed": GitCommands.diff(root: root, change: ren, hasCommits: true),
            "git-diff-untracked": GitCommands.diff(root: root, change: unt, hasCommits: true),
            "git-diff-nocommits": GitCommands.diff(root: root, change: mod, hasCommits: false),
            "git-discard-tracked": GitCommands.discard(root: root, change: ren),
            "git-discard-untracked": GitCommands.discard(root: root, change: unt),
            "git-commit": GitCommands.commit(root: root, message: "feat: «hola» 'x' $HOME\nsegunda", changes: [mod, ren, unt]),
            "git-push-upstream": GitCommands.push(root: root, hasUpstream: true),
            "git-push-new": GitCommands.push(root: root, hasUpstream: false),
            "git-pull": GitCommands.pull(root: root),
            "git-summaries": GitSummaryCommands.summaries(paths: ["/a", "~/b c", "/d'e"]),
            "claude-done-0": ClaudeDoneMessage.body(changedFiles: 0),
            "claude-done-1": ClaudeDoneMessage.body(changedFiles: 1),
            "claude-done-5": ClaudeDoneMessage.body(changedFiles: 5),
            "cm-suggest": CommitMessageSuggestion.command(
                claudePath: "/home/u/.local/bin/claude", root: root, changes: [mod, ren, quotedUntracked], hasCommits: true
            ),
            "cm-suggest-nocommits": CommitMessageSuggestion.command(
                claudePath: "/usr/bin/claude", root: "/srv/app", changes: [mod, quotedUntracked], hasCommits: false
            ),
            "cm-suggest-untracked": CommitMessageSuggestion.command(
                claudePath: "/usr/bin/claude", root: "/srv/app", changes: [quotedUntracked], hasCommits: true
            ),
            "wt-list": GitWorktreeCommands.list(path: root),
            "wt-add-new": GitWorktreeCommands.add(GitWorktreeRequest(
                repository: root, branch: "feat/login", createsBranch: true, base: "main", path: "\(root)-worktrees/feat-login"
            )),
            "wt-add-existing": GitWorktreeCommands.add(GitWorktreeRequest(
                repository: "/srv/app", branch: "fix/x", createsBranch: false, base: "", path: "/srv/app-worktrees/fix-x"
            )),
            "wt-remove": GitWorktreeCommands.remove(repository: "/srv/app", path: "/srv/app-worktrees/a b", force: false),
            "wt-remove-force": GitWorktreeCommands.remove(repository: "/srv/app", path: "/srv/app-worktrees/a b", force: true),
            "gh-status": GitHubCommands.status(root: root),
            "gh-create-pr": GitHubCommands.createPullRequest(root: root, draft: false),
            "gh-create-pr-draft": GitHubCommands.createPullRequest(root: root, draft: true),
            "gh-rerun": GitHubCommands.rerunFailed(root: root, runID: 42_853_364_727),
            "gh-repos": GitHubCommands.repositories(),
            "gh-clone-home": GitHubCommands.clone(try GitHubCloneRequest.make(repository: "victalejo/Argos", parent: "~/proy ectos", folder: "a'b")),
            "gh-clone-abs": GitHubCommands.clone(try GitHubCloneRequest.make(repository: "https://github.com/o/r.git", parent: "/srv", folder: "r")),
            "ports-listening": ListeningPortParser.command,
            "ports-publish": PortForwardServerFiles.publishCommand(deviceID: "a1b2-C3/..;x", deviceName: "Pixel de O'Brien\t8", forwards: forwards),
            "ports-unpublish": PortForwardServerFiles.unpublishCommand(deviceID: "DEV-1"),
            "ports-install": PortForwardServerFiles.installCommand,
            "ports-requests": PortForwardServerFiles.listRequestsCommand,
            "ports-dismiss": PortForwardServerFiles.dismissRequestCommand(port: 5173),
        ]
    }

    static func hooksAndStatus() throws -> [String: String] {
        let existing = #"{"model":"opus","env":{},"arr":[],"x":0.1,"y":1.0,"t":true,"u":"a/b\u0001 ","#
            + #""hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 transcribe.py"}]}],"#
            + #""Stop":[{"matcher":"","hooks":[{"type":"command","command":"x # argos-claude-status"},"#
            + #"{"type":"command","command":"mine"}]}]}}"#
        let settings = try ClaudeHookInstaller.parseSettings(existing)
        return [
            "hook-working": ClaudeHookInstaller.command(setting: .working),
            "hook-clear": ClaudeHookInstaller.command(setting: nil),
            "hooks-empty": try ClaudeHookInstaller.serialize(ClaudeHookInstaller.installing(into: [:])),
            "hooks-merged": try ClaudeHookInstaller.serialize(ClaudeHookInstaller.installing(into: settings)),
            "hooks-removed": try ClaudeHookInstaller.serialize(ClaudeHookInstaller.removing(from: settings)),
            "serialize-empty": try ClaudeHookInstaller.serialize([:]),
            "claude-activity": SSHService.claudeActivityCommand,
            "monitor-resources": SSHService.resourcesCommand,
        ].merging(try claudeLimits()) { current, _ in current }
    }

    /// Statusline de Argos para los límites de uso de Claude (`ClaudeLimitsInstaller`).
    static func claudeLimits() throws -> [String: String] {
        let existing = try ClaudeHookInstaller.parseSettings(
            #"{"model":"opus","statusLine":{"type":"command","command":"~/bin/mi barra.sh","padding":2}}"#
        )
        let installed = ClaudeLimitsInstaller.installing(into: existing)
        return [
            "limits-script": ClaudeLimitsInstaller.script,
            "limits-command": ClaudeLimitsInstaller.command,
            "limits-poll": ClaudeLimitsInstaller.pollCommand,
            "limits-installed": try ClaudeHookInstaller.serialize(installed.settings),
            "limits-installed-empty": try ClaudeHookInstaller.serialize(ClaudeLimitsInstaller.installing(into: [:]).settings),
            "limits-removed": try ClaudeHookInstaller.serialize(
                ClaudeLimitsInstaller.removing(from: installed.settings, previousCommand: installed.previousCommand ?? "")
            ),
            "limits-previous": ClaudeLimitsInstaller.previousFileContents(installed.previousCommand ?? ""),
            "usage-index-script": ClaudeUsageIndex.script,
            "usage-index-start": ClaudeUsageIndex.startCommand,
            "usage-index-read": ClaudeUsageIndex.readCommand,
            "task-dispatch-script": ClaudeTaskScript.script,
            "task-list": ClaudeTaskScript.listCommand,
            "schedule-list": ClaudeScheduleScripts.listCommand,
            "timer-install": ClaudeTaskTimer.installCommand,
            "timer-status": ClaudeTaskTimer.statusCommand,
            "timer-uninstall": ClaudeTaskTimer.uninstallCommand,
            "schedule-config": try ClaudeScheduleScripts.make(ClaudeScheduleScriptsTests.schedule(), claudePath: "/usr/local/bin/claude").config,
            "schedule-launch-tpl": try ClaudeScheduleScripts.make(ClaudeScheduleScriptsTests.schedule(), claudePath: "/usr/local/bin/claude").launch,
            "schedule-meta-tpl": try ClaudeScheduleScripts.make(ClaudeScheduleScriptsTests.schedule(), claudePath: "/usr/local/bin/claude").meta,
            "schedule-task-tpl": try ClaudeScheduleScripts.make(ClaudeScheduleScriptsTests.schedule(), claudePath: "/usr/local/bin/claude").task,
            "task-dispatch-enqueue": ClaudeTaskScript.dispatchCommand(["enqueue", "-Users-v-app", "abc123def456"]),
            "task-meta": ClaudeTaskRequest(prompt: "Arregla los tests\nque fallen", session: "app", window: 2, cleanContext: true, commit: true)
                .metaText(directory: "/Users/v/app"),
        ]
    }

    /// Mismas entradas que `HomeFileScriptsTest` de Android.
    static func homeFiles() -> [String: String] {
        let projects = ".config/argos/projects.json"
        let token = "0123456789abcdef0123456789abcdef"
        let inputs = [Data(), Data("a".utf8), Data("ñandú 123456789".utf8), Data(String(repeating: "x", count: 70_000).utf8)]
        return [
            "homefile-prepare": HomeFileScripts.prepare(projects, token: token),
            "homefile-prepare-claude": HomeFileScripts.prepare(".claude/settings.json", token: token),
            "homefile-commit-any": HomeFileScripts.commit(
                ".claude/settings.json", token: token, expectation: .any, backupSuffix: ".argos-backup"
            ),
            "homefile-commit-absent": HomeFileScripts.commit(
                projects, token: token, expectation: .absentOrEmpty, backupSuffix: ".argos-backup"
            ),
            "homefile-commit-fingerprint": HomeFileScripts.commit(
                projects, token: token, expectation: .fingerprint("1220704766 1"), backupSuffix: ".argos-backup"
            ),
            "homefile-commit-nobackup": HomeFileScripts.commit(
                projects, token: token, expectation: .fingerprint("it's"), backupSuffix: nil
            ),
            "cksum": inputs.map { PosixChecksum.fingerprint(of: $0) }.joined(separator: "\n"),
        ]
    }
}

// MARK: - Agentes (interrumpir, listado con estado, logs sembrados) y Doctor

extension GoldenCatalog {

    /// Mismas entradas que `AgentClosingGoldenTest` y `DoctorGoldenTest` de Android.
    static func androidClosing() -> [String: String] {
        var finished = AgentConversationState()
        AgentReducer.userSent(text: "revisa el código", to: &finished)
        AgentReducer.apply(.assistant([.thinking("pienso"), .text("Voy a leerlo."),
                                       .toolUse(id: "t1", name: "Read", input: .object(["file_path": .string("/srv/web/a.swift")]))]), to: &finished)
        AgentReducer.apply(.user([.toolResult(toolUseID: "t1", text: "línea 1\nlínea 2", isError: false)]), to: &finished)
        AgentReducer.apply(.assistant([.text("Todo bien.")]), to: &finished)
        AgentReducer.apply(.result(AgentResult(subtype: "success", isError: false, text: "Todo bien.", totalCostUSD: 0.01)), to: &finished)
        var open = AgentConversationState()
        AgentReducer.userSent(text: "hola", to: &open)
        AgentReducer.finished(error: "Se perdió la conexión", to: &open)
        return [
            "agent-interrupt": AgentProtocol.encodeInterrupt(requestID: "argos-interrupt-\(agentID)"),
            "overview": PersistentAgentScript.overview(),
            "seed-log": AgentTranscriptSeed.make(from: finished).lines.joined(separator: "\n"),
            "seed-log-open": AgentTranscriptSeed.make(from: open).lines.joined(separator: "\n"),
            "doctor-script": DoctorScript.command,
        ]
    }
}
