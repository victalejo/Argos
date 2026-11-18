//
//  AgentHardeningLogicTests.swift
//  ArgosTests
//
//  Lógica pura del endurecimiento de agentes: atención tolerante a líneas recortadas,
//  tope de resultados, guardia de memoria, tope de pestañas, inventario del servidor,
//  huérfanos del panel, reintentos y petición de interrupción.
//

import Foundation
import Testing
@testable import Argos

@Suite("Avisos tolerantes a líneas recortadas")
struct AgentAttentionTolerantTests {

    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"

    /// Un permiso de un `Write` enorme recortado a 400 bytes, como lo da `snapshots`.
    private var cutPermission: String {
        let input = String(repeating: "x", count: 70_000)
        let line = #"{"type":"control_request","request_id":"r7","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"content":""# + input + #""}}}"#
        return String(line.prefix(400))
    }

    @Test func unPermisoRecortadoSeDetecta() {
        #expect(AgentAttention.evaluate(logTail: cutPermission) == .needsPermission(tool: "Write"))
        // La marca de respondido lo cierra aunque el permiso viniera recortado.
        let answered = #"{"request_id":"r7","type":"argos_permission_answered"}"#
        #expect(AgentAttention.evaluate(logTail: cutPermission + "\n" + answered) == .none)
    }

    @Test func unPermisoIlegibleNoSeDaPorVisto() {
        let unreadable = #"{"type":"control_request","request":{"subtype":"can_use_tool","input":{"content":"xxxx"#
        #expect(AgentAttention.evaluate(logTail: unreadable) == .undetermined)
        // Basura sin tipo reconocible tampoco se puede evaluar.
        #expect(AgentAttention.evaluate(logTail: "zzzz\nyyyy") == .undetermined)
        #expect(AgentAttention.evaluate(logTail: "") == .none)

        let snapshot = AgentLogSnapshot(id: id, isAlive: true, logBytes: 500, title: "t", createdAt: Date(), tail: unreadable)
        let plan = AgentAttentionPlanner.notices(snapshots: [snapshot], seenBytes: [id: 100])
        #expect(plan.notices.isEmpty)
        #expect(plan.seen[id] == 100) // sin avanzar: el próximo refresco lo reintenta
    }

    @Test func unResultadoRecortadoSeResumeIgual() {
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Hecho: "# + String(repeating: "a", count: 2_000)
        let cut = String(result.prefix(400))
        guard case .finished(_, let isError) = AgentAttention.evaluate(logTail: cut) else {
            Issue.record("debía terminar")
            return
        }
        #expect(!isError)
    }

    @Test func unPromptRecortadoVuelveATrabajar() {
        let finished = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#
        let prompt = String((#"{"type":"user","message":{"role":"user","content":""# + String(repeating: "p", count: 900)).prefix(400))
        #expect(AgentAttention.evaluate(logTail: finished + "\n" + prompt) == .none)
        // Un resultado de herramienta recortado no cuenta como prompt.
        let toolResult = String((#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":""# + String(repeating: "r", count: 900)).prefix(400))
        #expect(AgentAttention.evaluate(logTail: finished + "\n" + toolResult) != .none)
    }

    @Test func extraeCadenasConEscapes() {
        #expect(AgentLogLineSummary.firstString(after: "\"a\":", in: #"{"a": "x\"y"}"#) == "x\"y")
        #expect(AgentLogLineSummary.firstString(after: "\"a\":", in: #"{"a":"sin cerrar"#) == nil)
        #expect(AgentLogLineSummary.firstString(after: "\"b\":", in: #"{"a":"x"}"#) == nil)
    }

    @Test func elScriptRecortaLasLineas() {
        let script = PersistentAgentScript.snapshots()
        #expect(script.contains("tail -n \(PersistentAgentScript.attentionTailLines)"))
        #expect(script.contains("cut -c 1-\(PersistentAgentScript.attentionLineBytes)"))
        #expect(script.contains("log.base")) // tamaño absoluto
        #expect(!script.contains("tail -c 16384"))
    }
}

@Suite("Tope de resultados en la conversación")
struct AgentTranscriptLimitsTests {

    @Test func losResultadosEnormesSeRecortanConIndicacion() throws {
        let big = String(repeating: "a", count: 12_000) + String(repeating: "b", count: 50_000) + String(repeating: "c", count: 2_000)
        let clipped = AgentTranscriptLimits.clip(big)
        #expect(clipped.count < AgentTranscriptLimits.maxToolResultCharacters + 200)
        #expect(clipped.hasPrefix(String(repeating: "a", count: 12_000)))
        #expect(clipped.hasSuffix(String(repeating: "c", count: 2_000)))
        #expect(clipped.contains("recortado: 50000 caracteres omitidos"))
        #expect(AgentTranscriptLimits.clip("corto") == "corto")

        var state = AgentConversationState()
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":""# + big + #""}]}}"#
        AgentReducer.apply(try #require(AgentProtocol.decode(line: line)), to: &state)
        guard case .toolResult(let text, _) = state.items.first?.kind else {
            Issue.record("faltaba el resultado")
            return
        }
        #expect(text == clipped)
    }
}

@Suite("Guardia antes de arrancar agentes")
struct AgentLaunchGuardTests {

    @Test func avisaConPocaMemoriaOMuchosAgentes() {
        #expect(AgentLaunchGuard.assess(freeMemoryKB: 4_000_000, liveAgents: 2) == .ok)
        #expect(AgentLaunchGuard.assess(freeMemoryKB: nil, liveAgents: 0) == .ok) // no Linux: no se sabe
        guard case .warning(let title, _) = AgentLaunchGuard.assess(freeMemoryKB: 500_000, liveAgents: 0) else {
            Issue.record("debía avisar por memoria")
            return
        }
        #expect(title.contains("memoria"))
        guard case .warning(let many, _) = AgentLaunchGuard.assess(freeMemoryKB: 8_000_000, liveAgents: 6) else {
            Issue.record("debía avisar por número")
            return
        }
        #expect(many.contains("6"))
    }

    @Test func elTopeDePestañasPreguntaEnVezDeDesalojar() {
        #expect(AgentTabCapacity.decide(running: 5, limit: 6) == .available)
        #expect(AgentTabCapacity.decide(running: 6, limit: 6) == .full(limit: 6))
    }

    @Test func esperaEntreReintentos() {
        #expect((1...7).map(AgentReconnectPolicy.delaySeconds(attempt:)) == [1, 2, 4, 8, 16, 30, 30])
        #expect(AgentReconnectPolicy.delaySeconds(attempt: 0) == 1)
    }

    @Test func preferenciaDeHibernacion() throws {
        let defaults = try #require(UserDefaults(suiteName: "argos-test-hib-\(UUID())"))
        #expect(AgentHibernationPreferences.idleHours(defaults: defaults) == PersistentAgentHibernation.defaultIdleHours)
        AgentHibernationPreferences.setIdleHours(0, defaults: defaults)
        #expect(!AgentHibernationPreferences.current(defaults: defaults).isEnabled)
        AgentHibernationPreferences.setIdleHours(13, defaults: defaults) // no es una opción
        #expect(AgentHibernationPreferences.idleHours(defaults: defaults) == PersistentAgentHibernation.defaultIdleHours)
        #expect(PersistentAgentHibernation(idleHours: 8).idleSeconds == 8 * 3600)
    }
}

@Suite("Inventario de agentes del servidor")
struct ServerAgentInventoryTests {

    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private let panelID = "11111111-2222-3333-4444-555555555555"

    private func panelArgs(_ sessionFlag: String = "--session-id", extra: String = "") -> String {
        "/home/u/.local/bin/claude -p --input-format stream-json --output-format stream-json --verbose "
            + "--permission-prompt-tool stdio --permission-mode default \(sessionFlag) \(panelID)\(extra)"
    }

    @Test func reconoceSoloLasConversacionesDelPanel() {
        #expect(ServerAgentInventory.panelSessionID(arguments: panelArgs()) == panelID)
        #expect(ServerAgentInventory.panelSessionID(arguments: panelArgs("--resume")) == panelID)
        // Persistente (lleva --replay-user-messages): no es del panel.
        #expect(ServerAgentInventory.panelSessionID(arguments: panelArgs(extra: " --replay-user-messages")) == nil)
        // claude interactivo de tmux, un grep o un shell con el texto: nunca.
        #expect(ServerAgentInventory.panelSessionID(arguments: "claude --session-id \(panelID)") == nil)
        #expect(ServerAgentInventory.panelSessionID(arguments: "grep -- " + panelArgs()) == nil)
        #expect(ServerAgentInventory.panelSessionID(arguments: "sh -c " + panelArgs()) == nil)
        #expect(ServerAgentInventory.panelSessionID(arguments: panelArgs().replacingOccurrences(of: panelID, with: "no-uuid")) == nil)
    }

    @Test func parseaPersistentesPanelYMemoria() throws {
        let meta = try JSONEncoder.projects.encode(PersistentAgentMeta(workingDirectory: "/srv/a", title: "a", createdAt: Date(timeIntervalSince1970: 5)))
        let output = """
        P|\(id)|1|512000|7200|4096|0|\(meta.base64EncodedString())
        P|\(UUID().uuidString)|0|0|99|10|0|\(meta.base64EncodedString())
        P|no-uuid|1|1|1|1|0|\(meta.base64EncodedString())
        M|4321|480000|\(panelArgs())
        M|4322|1000|vim notas.txt --input-format stream-json
        MEM|2048000
        basura
        """
        let inventory = ServerAgentInventory.parse(output)
        #expect(inventory.agents.count == 3)
        #expect(inventory.freeMemoryKB == 2_048_000)
        #expect(inventory.liveAgents.count == 2)
        #expect(inventory.liveResidentKB == 992_000)
        #expect(inventory.agents.first?.residentKB == 512_000) // vivos primero, por memoria
        let panel = try #require(inventory.agents.first { if case .panel = $0.kind { return true } else { return false } })
        #expect(panel.kind == .panel(pid: 4321) && panel.sessionID == panelID && panel.idleSeconds == nil)
        #expect(inventory.hibernationCandidates(idleSeconds: 3600).map(\.sessionID) == [id])
        #expect(inventory.hibernationCandidates(idleSeconds: 10_000).isEmpty)
    }

    @Test func noHibernaLosQueEsperanPermiso() throws {
        let meta = try JSONEncoder.projects.encode(PersistentAgentMeta(workingDirectory: "/srv", title: "s", createdAt: Date()))
        let inventory = ServerAgentInventory.parse("P|\(id)|1|1|99999|1|1|\(meta.base64EncodedString())")
        #expect(inventory.agents.first?.hasPendingPermission == true)
        #expect(inventory.hibernationCandidates(idleSeconds: 60).isEmpty)
    }

    @Test func lasAccionesComprubanAntesDeMatar() {
        let stop = ServerAgentInventory.stopPanel([(pid: 4321, sessionID: panelID), (pid: 1, sessionID: panelID), (pid: 9, sessionID: "x")])
        #expect(stop.contains("4321:\(panelID)"))
        #expect(stop.contains("pm()")) // cada señal comprueba antes el id
        #expect(stop.contains("kill -s KILL"))
        #expect(!stop.contains(" 1:"))
        #expect(!stop.contains("9:x"))
        #expect(ServerAgentInventory.stopPanel([]) == "true")
        #expect(ServerAgentInventory.stopPanelSessions(["no-uuid"]) == "true")
        let hibernate = ServerAgentInventory.hibernate(ids: [id, "../x"], minIdleSeconds: 3600)
        #expect(hibernate.contains("hibernatedAt") && hibernate.contains("-ge 3600"))
        #expect(!hibernate.contains("../x"))
        #expect(!ServerAgentInventory.stopPersistent(ids: ["../x"]).contains("rm -rf"))
        // Cada agente en su subshell: uno atascado no corta los demás y queda anotado.
        let both = ServerAgentInventory.stopPersistent(ids: [id, panelID])
        #expect(both.components(separatedBy: ServerAgentInventory.failedMarker).count == 3)
        #expect(ServerAgentInventory.failures(in: "x\n\(ServerAgentInventory.failedMarker) \(id)\n") == [id])
        // El script no se encuentra a sí mismo en `ps`.
        #expect(!ServerAgentInventory.script().contains("stream-json"))
    }

    @Test func huerfanosSoloLosDeEsteDispositivoSinPestañaViva() {
        let other = "99999999-2222-3333-4444-555555555555"
        let openTab = "aaaaaaaa-2222-3333-4444-555555555555"
        let gone = "bbbbbbbb-2222-3333-4444-555555555555"
        func panel(_ session: String, pid: Int32) -> ServerAgentProcess {
            ServerAgentProcess(sessionID: session, kind: .panel(pid: pid), isAlive: true, residentKB: 1, idleSeconds: nil, hasPendingPermission: false)
        }
        let inventory = ServerAgentInventory(agents: [panel(panelID, pid: 10), panel(other, pid: 11), panel(openTab, pid: 12)], freeMemoryKB: nil)
        let plan = AgentPanelOrphans.plan(
            inventory: inventory,
            registered: [panelID, openTab, gone],
            liveTabSessionIDs: [openTab]
        )
        #expect(plan.orphans.map(\.sessionID) == [panelID]) // el de otro dispositivo no se toca
        #expect(plan.registry == [panelID, openTab]) // el que ya no corre se olvida
    }

    @Test func elRegistroRecuerdaPorServidor() throws {
        let registry = AgentPanelRegistry(suiteName: "argos-test-reg-\(UUID())")
        let server = UUID()
        registry.record("A", serverID: server)
        registry.record("b", serverID: server)
        registry.record("a", serverID: server)
        #expect(registry.sessionIDs(serverID: server) == ["b", "a"])
        #expect(registry.sessionIDs(serverID: UUID()).isEmpty)
        registry.forget(serverID: server)
        #expect(registry.sessionIDs(serverID: server).isEmpty)
    }
}

@Suite("Protocolo: interrupción y conteo de bytes")
struct AgentProtocolHardeningTests {

    @Test func laInterrupcionEsUnaPeticionDeControl() throws {
        let line = AgentProtocol.encodeInterrupt(requestID: "r-1")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "control_request")
        #expect(object["request_id"] as? String == "r-1")
        #expect((object["request"] as? [String: String]) == ["subtype": "interrupt"])
    }

    @Test func elBufferCuentaLosBytesDeCadaLinea() {
        var buffer = NDJSONLineBuffer()
        let first = buffer.appendCountingBytes(Array("ñ1\n{\"a\"".utf8))
        #expect(first.map(\.byteCount) == [4])
        #expect(first.first?.text == "ñ1")
        let second = buffer.appendCountingBytes([0xFF, 0x0A] + Array(":1}\n".utf8))
        #expect(second.map(\.byteCount) == [6, 4]) // `{"a"` + 0xFF + \n, y `:1}` + \n
        #expect(second.first?.text == nil) // no es UTF-8, pero sus bytes cuentan
    }

    @Test func laCabeceraDelEngancheSeReconoce() {
        let header = PersistentAgentScript.parseLogBase(#"{"type":"argos_log_base","base":100,"from":5}"#)
        #expect(header?.base == 100 && header?.from == 5)
        #expect(PersistentAgentScript.parseLogBase(#"{"type":"assistant"}"#) == nil)
        #expect(PersistentAgentScript.parseLogBase(#"{"type":"argos_log_base","base":-1,"from":5}"#) == nil)
    }

    @Test func elPanelPuedeReanudar() {
        let resumed = ClaudeAgentCommand.build(claudePath: "/c", workingDirectory: "/srv", sessionID: "s1", resume: true)
        #expect(resumed.contains("--resume s1"))
        #expect(!resumed.contains("--session-id"))
        #expect(ClaudeAgentCommand.build(claudePath: "/c", workingDirectory: "/srv", sessionID: "s1").contains("--session-id s1"))
    }
}
