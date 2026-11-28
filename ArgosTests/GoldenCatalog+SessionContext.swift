//
//  GoldenCatalog+SessionContext.swift
//  ArgosTests
//
//  Goldens del contexto al arrancar Claude: el script, el hook `SessionStart` (instalado
//  APARTE del indicador) y cómo queda settings.json cuando cualquier versión reinstala o
//  quita el indicador. Android aún no instala este hook (`pendingAndroidPort`), pero SÍ
//  comprueba que su `ClaudeHookInstaller` lo conserva (`SwiftParityGoldenTest`).
//

import Foundation
@testable import Argos

extension GoldenCatalog {

    static func sessionContext() throws -> [String: String] {
        let withContext = SessionContextHookInstaller.installing(into: ClaudeHookInstaller.installing(into: [:]))
        return [
            "session-context-script": SessionContextScript.source,
            "session-context-hook": SessionContextHookInstaller.command,
            "session-context-preview": SessionContextScript.previewCommand(projectPath: "/home/u/mi repo's"),
            "hooks-with-session-context": try ClaudeHookInstaller.serialize(withContext),
            "hooks-session-context-reinstalled": try ClaudeHookInstaller.serialize(ClaudeHookInstaller.installing(into: withContext)),
            "hooks-session-context-status-removed": try ClaudeHookInstaller.serialize(ClaudeHookInstaller.removing(from: withContext)),
        ]
    }
}
