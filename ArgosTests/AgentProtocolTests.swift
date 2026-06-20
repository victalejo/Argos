//
//  AgentProtocolTests.swift
//  ArgosTests
//
//  Cobertura de la capa pura del protocolo stream-json del CLI `claude`:
//  decodificación de eventos, codificación de mensajes/respuestas y el buffer NDJSON.
//  Usa fragmentos JSON reales capturados de `claude` v2.1.183.
//

import Testing
import Foundation
@testable import Argos

struct AgentProtocolTests {

    // MARK: - Decodificación

    @Test("init se decodifica con session_id y model")
    func decodeInit() throws {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-opus-4-8[1m]","cwd":"/tmp"}"#
        guard case .initialized(let info)? = AgentProtocol.decode(line: line) else {
            Issue.record("Se esperaba .initialized"); return
        }
        #expect(info.sessionID == "abc-123")
        #expect(info.model == "claude-opus-4-8[1m]")
    }

    @Test("assistant con texto")
    func decodeAssistantText() throws {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hola"}]},"session_id":"s"}"#
        guard case .assistant(let blocks)? = AgentProtocol.decode(line: line) else {
            Issue.record("Se esperaba .assistant"); return
        }
        #expect(blocks == [.text("hola")])
    }

    @Test("assistant con tool_use conserva nombre e input")
    func decodeAssistantToolUse() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls","timeout":5}}]}}"#
        guard case .assistant(let blocks)? = AgentProtocol.decode(line: line),
              case .toolUse(let id, let name, let input) = blocks.first else {
            Issue.record("Se esperaba .toolUse"); return
        }
        #expect(id == "toolu_1")
        #expect(name == "Bash")
        #expect(input["command"]?.stringValue == "ls")
        #expect(input["timeout"] == .int(5))
    }

    @Test("control_request can_use_tool → permissionRequest")
    func decodePermissionRequest() throws {
        let line = #"{"type":"control_request","request_id":"req-9","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/tmp/x.txt","content":"H"},"tool_use_id":"toolu_2"}}"#
        guard case .permissionRequest(let request)? = AgentProtocol.decode(line: line) else {
            Issue.record("Se esperaba .permissionRequest"); return
        }
        #expect(request.id == "req-9")
        #expect(request.toolName == "Write")
        #expect(request.displayName == "Write")
        #expect(request.toolUseID == "toolu_2")
        #expect(request.input["file_path"]?.stringValue == "/tmp/x.txt")
    }

    @Test("control_cancel_request → permissionCancel")
    func decodeCancel() throws {
        let line = #"{"type":"control_cancel_request","request_id":"req-9"}"#
        #expect(AgentProtocol.decode(line: line) == .permissionCancel(requestID: "req-9"))
    }

    @Test("result conserva subtype, error y costo")
    func decodeResult() throws {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"listo","total_cost_usd":0.21}"#
        guard case .result(let result)? = AgentProtocol.decode(line: line) else {
            Issue.record("Se esperaba .result"); return
        }
        #expect(result.subtype == "success")
        #expect(result.isError == false)
        #expect(result.text == "listo")
        #expect(result.totalCostUSD == 0.21)
    }

    @Test("user con tool_result")
    func decodeUserToolResult() throws {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"salida","is_error":false}]}}"#
        guard case .user(let blocks)? = AgentProtocol.decode(line: line) else {
            Issue.record("Se esperaba .user"); return
        }
        #expect(blocks == [.toolResult(toolUseID: "toolu_1", text: "salida", isError: false)])
    }

    @Test("hooks y system no-init se ignoran")
    func decodeIgnored() throws {
        let line = #"{"type":"system","subtype":"hook_started","hook_id":"h"}"#
        #expect(AgentProtocol.decode(line: line) == .ignored(type: "system", subtype: "hook_started"))
    }

    @Test("línea inválida o vacía → nil", arguments: ["", "   ", "no es json", "{roto"])
    func decodeInvalid(line: String) throws {
        #expect(AgentProtocol.decode(line: line) == nil)
    }

    // MARK: - Codificación

    @Test("encodeUserMessage produce el envelope correcto")
    func encodeUser() throws {
        let line = AgentProtocol.encodeUserMessage(text: "hola mundo")
        let object = try jsonObject(line)
        #expect(object["type"] as? String == "user")
        let message = try #require(object["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        #expect(message["content"] as? String == "hola mundo")
    }

    @Test("encodePermissionResponse allow incluye updatedInput")
    func encodeAllow() throws {
        let line = AgentProtocol.encodePermissionResponse(
            requestID: "req-9",
            decision: .allow(updatedInput: .object(["command": .string("ls")]))
        )
        let response = try nestedResponse(line)
        #expect(response["behavior"] as? String == "allow")
        let updated = try #require(response["updatedInput"] as? [String: Any])
        #expect(updated["command"] as? String == "ls")
    }

    @Test("encodePermissionResponse deny incluye mensaje y request_id")
    func encodeDeny() throws {
        let line = AgentProtocol.encodePermissionResponse(
            requestID: "req-9",
            decision: .deny(message: "no")
        )
        let object = try jsonObject(line)
        #expect(object["type"] as? String == "control_response")
        let outer = try #require(object["response"] as? [String: Any])
        #expect(outer["subtype"] as? String == "success")
        #expect(outer["request_id"] as? String == "req-9")
        let inner = try #require(outer["response"] as? [String: Any])
        #expect(inner["behavior"] as? String == "deny")
        #expect(inner["message"] as? String == "no")
    }

    // MARK: - Buffer NDJSON

    @Test("el buffer parte líneas completas y conserva el resto parcial")
    func lineBuffering() throws {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.append(Array(#"{"a":1}"#.utf8)) == [])           // sin newline aún
        #expect(buffer.append(Array("\n{\"b\":2".utf8)) == [#"{"a":1}"#]) // cierra la 1ª
        #expect(buffer.append(Array("}\n".utf8)) == [#"{"b":2}"#])        // cierra la 2ª
    }

    @Test("el buffer maneja varias líneas en un solo chunk")
    func multipleLinesOneChunk() throws {
        var buffer = NDJSONLineBuffer()
        let lines = buffer.append(Array("uno\ndos\ntres\n".utf8))
        #expect(lines == ["uno", "dos", "tres"])
    }

    // MARK: - Helpers

    private func jsonObject(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func nestedResponse(_ line: String) throws -> [String: Any] {
        let outer = try #require(try jsonObject(line)["response"] as? [String: Any])
        return try #require(outer["response"] as? [String: Any])
    }
}
