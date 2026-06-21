//
//  AgentReducerTests.swift
//  ArgosTests
//
//  El reducer es puro y determinista (ids enteros): cubre las transiciones de estado
//  del panel de agente sin red ni UI.
//

import Testing
@testable import Argos

struct AgentReducerTests {

    @Test("estado inicial: listo (idle) y vacío")
    func initialState() {
        let state = AgentConversationState()
        #expect(state.status == .idle)
        #expect(state.items.isEmpty)
        #expect(state.pendingPermission == nil)
    }

    @Test("init fija session_id y pasa a idle")
    func applyInit() {
        var state = AgentConversationState()
        AgentReducer.apply(.initialized(AgentInit(sessionID: "s1", model: "m")), to: &state)
        #expect(state.sessionID == "s1")
        #expect(state.status == .idle)
    }

    @Test("texto del asistente se añade; thinking vacío se ignora")
    func applyAssistant() {
        var state = AgentConversationState()
        AgentReducer.apply(.assistant([.thinking(""), .text("hola"), .text("")]), to: &state)
        #expect(state.items.count == 1)
        #expect(state.items.first?.kind == .assistantText("hola"))
        #expect(state.items.first?.id == 0)
    }

    @Test("tool_use se añade con nombre e input")
    func applyToolUse() {
        var state = AgentConversationState()
        AgentReducer.apply(
            .assistant([.toolUse(id: "t", name: "Bash", input: .object(["command": .string("ls")]))]),
            to: &state
        )
        #expect(state.items.first?.kind == .toolUse(name: "Bash", input: .object(["command": .string("ls")])))
    }

    @Test("permissionRequest fija el permiso pendiente")
    func applyPermission() {
        var state = AgentConversationState()
        let request = AgentPermissionRequest(id: "r1", toolName: "Write", displayName: nil, input: .object([:]), toolUseID: nil)
        AgentReducer.apply(.permissionRequest(request), to: &state)
        #expect(state.pendingPermission == request)
    }

    @Test("permissionCancel limpia solo si coincide el id")
    func applyCancel() {
        var state = AgentConversationState()
        let request = AgentPermissionRequest(id: "r1", toolName: "Write", displayName: nil, input: .object([:]), toolUseID: nil)
        AgentReducer.apply(.permissionRequest(request), to: &state)
        AgentReducer.apply(.permissionCancel(requestID: "otro"), to: &state)
        #expect(state.pendingPermission == request)        // no coincide → intacto
        AgentReducer.apply(.permissionCancel(requestID: "r1"), to: &state)
        #expect(state.pendingPermission == nil)            // coincide → limpio
    }

    @Test("result añade un item y vuelve a idle")
    func applyResult() {
        var state = AgentConversationState()
        state.status = .working
        AgentReducer.apply(.result(AgentResult(subtype: "success", isError: false, text: "ok", totalCostUSD: 0.1)), to: &state)
        #expect(state.status == .idle)
        if case .result(let result)? = state.items.last?.kind {
            #expect(result.text == "ok")
        } else {
            Issue.record("Se esperaba un item .result")
        }
    }

    @Test("userSent añade el prompt y pasa a working")
    func userSent() {
        var state = AgentConversationState()
        state.status = .idle
        AgentReducer.userSent(text: "haz algo", to: &state)
        #expect(state.items.last?.kind == .userText("haz algo"))
        #expect(state.status == .working)
    }

    @Test("finished con error marca failed y añade el error")
    func finishedError() {
        var state = AgentConversationState()
        AgentReducer.finished(error: "se cayó", to: &state)
        #expect(state.status == .failed("se cayó"))
        #expect(state.items.last?.kind == .error("se cayó"))
    }

    @Test("finished sin error marca finished")
    func finishedOK() {
        var state = AgentConversationState()
        AgentReducer.finished(error: nil, to: &state)
        #expect(state.status == .finished)
    }

    @Test("ids incrementales y reducción determinista")
    func deterministic() {
        func run() -> AgentConversationState {
            var state = AgentConversationState()
            AgentReducer.apply(.initialized(AgentInit(sessionID: "s", model: nil)), to: &state)
            AgentReducer.userSent(text: "hola", to: &state)
            AgentReducer.apply(.assistant([.text("respuesta")]), to: &state)
            AgentReducer.apply(.result(AgentResult(subtype: "success", isError: false, text: nil, totalCostUSD: nil)), to: &state)
            return state
        }
        #expect(run() == run())
        #expect(run().items.map(\.id) == [0, 1, 2])
    }
}
