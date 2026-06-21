//
//  AgentAuthParsingTests.swift
//  ArgosTests
//
//  El parseo de `claude auth status --json` debe tolerar ruido de perfil/avisos que
//  algunos servidores imprimen alrededor del JSON.
//

import Testing
@testable import Argos

struct AgentAuthParsingTests {

    @Test("extrae el objeto JSON aunque haya ruido alrededor")
    func extractsWithNoise() {
        let noisy = "Welcome to Ubuntu\n{\"loggedIn\":true,\"subscriptionType\":\"max\"}\nbye"
        #expect(SSHService.extractJSONObject(noisy) == "{\"loggedIn\":true,\"subscriptionType\":\"max\"}")
    }

    @Test("JSON limpio se devuelve igual")
    func cleanJSON() {
        let clean = "{\"loggedIn\":false}"
        #expect(SSHService.extractJSONObject(clean) == clean)
    }

    @Test("sin objeto JSON devuelve nil", arguments: ["", "no hay json", "}{ invertido"])
    func noObject(text: String) {
        #expect(SSHService.extractJSONObject(text) == nil)
    }
}
