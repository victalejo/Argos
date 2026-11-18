//
//  IntegrationDoctorTests.swift
//  ArgosTests
//
//  El script REAL del Doctor (`DoctorScript`) en el servidor de pruebas: su salida debe
//  entenderla el parser entera y, en Linux (dash, procps, GNU), ninguna comprobación debe
//  quedar en «No se pudo comprobar» por un fallo del propio script.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Doctor del servidor")
struct Doctor {

    @Test("La salida del script se entiende entera y cuadra con el servidor", .timeLimit(.minutes(2)))
    func scriptOutputParses() async throws {
        let box = try await RemoteBox.open("doctor")
        defer { IntegrationCleanup.later { await box.close() } }
        // Un projects.json válido y los hooks instalados, para cubrir esas ramas.
        try await box.sh("rm -rf \"$HOME/\(SSHService.projectsRelativePath)\"* \"$HOME/.claude\"")
        try await box.service.saveProjects([Project(name: "doctor", path: box.root)])
        try await box.service.installClaudeHooks()

        let output = try await box.sh(DoctorScript.command)
        let facts = DoctorFacts.parse(output)
        #expect(facts.isComplete, "El script no llegó al final:\n\(output)")
        #expect(facts["format"] == String(DoctorScript.formatVersion))
        #expect(facts["os"] == IntegrationRemote.serverOS || IntegrationRemote.serverOS.isEmpty)
        #expect(facts.flag("claude.present") == true)
        #expect(facts["claude.version"]?.contains("simulado") == true, "Debe encontrar el claude simulado")
        #expect(facts["claude.auth"] == "out")
        #expect(facts["projects.file"] == "ok")
        #expect(facts["hooks.settings"] == "ok")
        #expect(Int(facts["hooks.marker"] ?? "") ?? 0 > 0)
        #expect(facts.numbers("disk.home", count: 2) != nil, "disk.home: \(facts["disk.home"] ?? "-")")
        if try await box.has("python3") { #expect(facts["projects.json"] == "valid") }
        if try await box.has("tmux") { #expect(facts["tmux.version"]?.hasPrefix("tmux") == true) }

        let checks = DoctorEvaluator.evaluate(facts, context: .init(hooksUpToDate: true))
        let unknown = checks.filter { $0.status == .unknown }.map { "\($0.id): \($0.detail)" }
        if IntegrationRemote.isLinux {
            #expect(facts.flag("tool.timeout") == true && facts.flag("tool.findprintf") == true)
            #expect(facts.numbers("mem", count: 4) != nil, "mem: \(facts["mem"] ?? "-")")
            #expect(facts.numbers("claude.procs", count: 2) != nil)
            #expect(unknown.isEmpty, "Comprobaciones sin resultado en Linux:\n\(unknown.joined(separator: "\n"))\n\(output)")
        }
        try await box.sh("rm -rf \"$HOME/\(SSHService.projectsRelativePath)\"* \"$HOME/.claude\"")
    }

    @Test("El script corre igual bajo dash", .enabled(if: IntegrationRemote.isLinux, IntegrationRemote.linuxOnly),
          .timeLimit(.minutes(1)))
    func runsUnderDash() async throws {
        let box = try await RemoteBox.open("doctor-dash")
        defer { IntegrationCleanup.later { await box.close() } }
        guard try await box.has("dash") else { return }
        let output = try await box.run("dash -c \(box.q(DoctorScript.command))")
        #expect(output.exitCode == 0)
        #expect(output.stderr.isEmpty, "dash avisó: \(output.stderr)")
        #expect(DoctorFacts.parse(output.stdout).isComplete)
    }
}

}
