//
//  SeededLogAttentionTests.swift
//  ArgosTests
//
//  Un log sembrado por el Mac (cierra con un `result` `argos_seed`) no avisa de «terminó»
//  ni en los avisos del iPhone ni en la bandeja del Mac, como en Android.
//

import Foundation
import Testing
@testable import Argos

@Suite("Avisos: un log sembrado no avisa de «terminó»")
struct SeededLogAttentionTests {

    private let seed = #"{"type":"result","subtype":"argos_seed","is_error":false}"#
    private let real = #"{"type":"result","subtype":"success","is_error":false,"result":"Hecho"}"#

    @Test func elResultSembradoEstaQuietoPeroNoAvisa() {
        let attention = AgentAttention.evaluate(logTail: #"{"type":"assistant","message":{"content":[]}}"# + "\n" + seed)
        #expect(attention == .finished(summary: nil, isError: false, seeded: true))
        #expect(attention.notification(agentTitle: "t") == nil)
        // Recortado (no es JSON válido) se reconoce igual.
        let cut = String((#"{"type":"result","subtype":"argos_seed","is_error":false,"result":""# + String(repeating: "a", count: 900)).prefix(400))
        #expect(AgentAttention.evaluate(logTail: cut) == .finished(summary: nil, isError: false, seeded: true))
        // Un turno de verdad después sí avisa.
        let later = AgentAttention.evaluate(logTail: seed + "\n" + real)
        #expect(later == .finished(summary: "Hecho", isError: false))
        #expect(later.notification(agentTitle: "t") != nil)
    }

    @Test func elPlanificadorNoAvisaDeUnLogSembrado() {
        let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
        let snapshot = AgentLogSnapshot(id: id, isAlive: true, logBytes: 900, title: "t", createdAt: Date(), tail: seed)
        let plan = AgentAttentionPlanner.notices(snapshots: [snapshot], seenBytes: [:])
        #expect(plan.notices.isEmpty)
        #expect(plan.seen[id] == 900) // visto: no se reevalúa en cada refresco
    }

    @Test func elRastreadorDelMacNoLoPoneEnLaBandeja() {
        let serverID = UUID()
        let meta = PersistentAgentMeta(workingDirectory: "/srv", title: "srv", createdAt: Date())
        func overview(bytes: Int, attention: AgentAttention) -> PersistentAgentOverview {
            PersistentAgentOverview(id: "a1", isAlive: true, logBytes: bytes, idleSeconds: 0, meta: meta, attention: attention)
        }
        var tracker = PersistentAgentAttentionTracker()
        tracker.absorb(serverID: serverID, agents: [])
        tracker.absorb(serverID: serverID, agents: [overview(bytes: 900, attention: .finished(summary: nil, isError: false, seeded: true))])
        #expect(tracker.notices(agents: [serverID: [overview(bytes: 900, attention: .finished(summary: nil, isError: false, seeded: true))]]).isEmpty)
        #expect(overview(bytes: 900, attention: .finished(summary: nil, isError: false, seeded: true)).activity == .idle)
        // Cuando termina un turno de verdad, sí.
        let done = overview(bytes: 1_500, attention: .finished(summary: "ok", isError: false))
        tracker.absorb(serverID: serverID, agents: [done])
        #expect(tracker.notices(agents: [serverID: [done]]).count == 1)
    }
}
