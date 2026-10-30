//
//  AgentRealStreamTests.swift
//  ArgosTests
//
//  Reproduce una sesión REAL de `claude -p --input-format stream-json` (CLI 2026,
//  grabada contra un servidor; saneada): 3 turnos en el mismo proceso — saludo,
//  Write con permiso concedido y Bash con permiso denegado. Fija que el decodificador
//  tolera los eventos nuevos (hooks, thinking_tokens, commands_changed, rate limit) y
//  que el reducer reconstruye la conversación.
//

import Foundation
import Testing
@testable import Argos

private final class FixtureMarker {}

@Suite("Agente: sesión stream-json real")
struct AgentRealStreamTests {

    private func lines() throws -> [String] {
        let url = try #require(
            Bundle(for: FixtureMarker.self).url(forResource: "agent-stream-real", withExtension: "ndjson")
        )
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    @Test("Todas las líneas se decodifican (las desconocidas como 'ignored')")
    func decodesEveryLine() throws {
        let lines = try lines()
        #expect(lines.count == 33)
        for line in lines {
            #expect(AgentProtocol.decode(line: line) != nil, "no decodifica: \(line.prefix(80))")
        }
    }

    @Test("El reducer reconstruye los 3 turnos y los permisos")
    func reducesConversation() throws {
        var state = AgentConversationState()
        var permissionTools: [String] = []
        for line in try lines() {
            guard let event = AgentProtocol.decode(line: line) else { continue }
            if case .permissionRequest(let request) = event { permissionTools.append(request.toolName) }
            AgentReducer.apply(event, to: &state)
        }

        let results = state.items.filter { if case .result = $0.kind { return true } else { return false } }
        #expect(results.count == 3)
        #expect(state.items.contains { $0.kind == .assistantText("hola") })
        #expect(state.items.contains { if case .toolUse(let name, _) = $0.kind { return name == "Write" } else { return false } })
        #expect(permissionTools == ["Write", "Bash"])
        #expect(state.sessionID == "00000000-0000-4000-8000-000000000000")
        #expect(state.status == .idle)
    }
}
