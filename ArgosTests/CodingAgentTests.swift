//
//  CodingAgentTests.swift
//  ArgosTests
//
//  Catálogo de agentes de terminal: detección por proceso o nombre de ventana y
//  lectura de la salida del script que averigua cuáles están instalados.
//

import Testing
@testable import Argos

@Suite("Agentes de terminal")
struct CodingAgentTests {

    @Test("Detecta por el proceso en primer plano", arguments: [
        ("claude", CodingAgent.claude), ("codex", .codex), ("grok", .grok), ("Claude", .claude),
    ])
    func detectsByCommand(command: String, expected: CodingAgent) {
        #expect(CodingAgent.detect(command: command, windowName: "zsh") == expected)
    }

    @Test("Detecta por el nombre que Argos le puso a la ventana")
    func detectsByWindowName() {
        #expect(CodingAgent.detect(command: "node", windowName: "Codex") == .codex)
        #expect(CodingAgent.detect(command: nil, windowName: "Claude Code") == .claude)
    }

    @Test("Si la ventana volvió a su shell, el nombre ya no cuenta (el agente salió)")
    func exitedAgentIsNotDetected() {
        #expect(CodingAgent.detect(command: "zsh", windowName: "Claude Code") == nil)
        #expect(CodingAgent.detect(command: "-bash", windowName: "Codex") == nil)
    }

    @Test("Un shell o un programa cualquiera no es un agente")
    func otherProcessesAreNotAgents() {
        #expect(CodingAgent.detect(command: "zsh", windowName: "zsh") == nil)
        #expect(CodingAgent.detect(command: "vim", windowName: "claude-notes") == nil)
    }

    @Test("Solo cuentan las líneas marcadas con un binario conocido")
    func parsesInstalled() {
        let output = """
        Bienvenido a Ubuntu (MOTD)
        claude
        argos-agent:claude
        argos-agent:grok
        argos-agent:cursor
          argos-agent:codex  
        """
        #expect(CodingAgent.parseInstalled(output) == [.claude, .grok, .codex])
    }

    @Test("Sin la marca de fin, la salida no es fiable")
    func incompleteOutput() {
        #expect(!CodingAgent.installedOutputIsComplete(""))
        #expect(!CodingAgent.installedOutputIsComplete("zsh:1: no matches found: /x/*/bin"))
        #expect(CodingAgent.installedOutputIsComplete("argos-agent:claude\nargos-agents-done\n"))
    }

    @Test("Salida vacía => ninguno instalado")
    func parsesEmpty() {
        #expect(CodingAgent.parseInstalled("").isEmpty)
    }

    @Test("El script busca todos los binarios y termina con éxito")
    func scriptCoversAllAgents() {
        let script = CodingAgent.installedAgentsScript
        for agent in CodingAgent.allCases {
            #expect(script.contains(agent.binary))
        }
        #expect(script.contains(CodingAgent.installedMarker))
        #expect(script.hasSuffix("exit 0"))
        #expect(script.contains(CodingAgent.installedDoneMarker))
    }

    @Test("Cada agente tiene una tecla de menú distinta")
    func uniqueMenuKeys() {
        let keys = CodingAgent.allCases.map(\.menuKey)
        #expect(Set(keys).count == keys.count)
    }
}
