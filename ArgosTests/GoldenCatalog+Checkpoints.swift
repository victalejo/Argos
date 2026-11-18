//
//  GoldenCatalog+Checkpoints.swift
//  ArgosTests
//
//  Goldens de los puntos de restauración: el script, el hook de captura (instalado APARTE
//  del indicador) y los comandos de la app. Android aún no los porta
//  (`GoldenParityTests.pendingAndroidPort`): cuando lo haga, sus tests deben usar estas
//  mismas entradas.
//

import Foundation
@testable import Argos

extension GoldenCatalog {

    static func checkpoints() throws -> [String: String] {
        let status = ClaudeHookInstaller.installing(into: [:])
        let withCheckpoint = CheckpointHookInstaller.installing(into: status)
        let root = "/home/u/mi repo's"
        return [
            "checkpoint-script": CheckpointScript.source,
            "checkpoint-hook": CheckpointHookInstaller.command,
            "hooks-with-checkpoint": try ClaudeHookInstaller.serialize(withCheckpoint),
            "hooks-checkpoint-removed": try ClaudeHookInstaller.serialize(CheckpointHookInstaller.removing(from: withCheckpoint)),
            "checkpoint-list": CheckpointCommands.list(path: root),
            "checkpoint-files": CheckpointCommands.files(root: root, from: "abc123", to: CheckpointCommands.worktree),
            "checkpoint-preview": CheckpointCommands.preview(root: root, commit: "abc123", force: false),
            "checkpoint-restore": CheckpointCommands.restore(root: root, commit: "abc123", expectedTree: "def456", path: nil),
            "checkpoint-restore-file": CheckpointCommands.restore(root: root, commit: "abc123", expectedTree: "def456", path: "src/a b'.swift"),
            "checkpoint-enable": CheckpointCommands.enable(root: root),
            "checkpoint-disable": CheckpointCommands.disable(root: root),
        ]
    }
}
