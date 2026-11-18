//
//  DoctorEvaluatorTests.swift
//  ArgosTests
//
//  Parser y reglas de severidad del Doctor del servidor con salidas de ejemplo de Linux.
//

import Foundation
import Testing
@testable import Argos

/// Salida típica de un Ubuntu sano, con la que cada test cambia lo que le interesa.
private func sampleOutput(overriding overrides: [String: String] = [:], removing removed: Set<String> = []) -> String {
    var lines: [(String, String)] = [
        ("format", "1"), ("os", "Linux"), ("arch", "x86_64"), ("shell", "bash"),
        ("clock", "1800000000"), ("pm", "apt-get"),
        ("tmux.present", "yes"), ("tmux.version", "tmux 3.3a"),
        ("git.present", "yes"), ("git.version", "git version 2.43.0"),
        ("claude.present", "yes"), ("claude.version", "2.1.5 (Claude Code)"), ("claude.auth", "in"),
        ("gh.present", "yes"), ("gh.version", "gh version 2.45.0 (2024-03-01)"), ("gh.auth", "in"),
        ("tool.timeout", "yes"), ("tool.cksum", "yes"), ("tool.base64", "yes"), ("tool.python3", "yes"),
        ("tool.mkfifo", "yes"), ("tool.nohup", "yes"), ("tool.awk", "yes"),
        ("tool.base64d", "yes"), ("tool.findprintf", "yes"),
        ("disk.home", "100000000 60000000"), ("disk.tmp", "50000000 40000000"),
        ("mem", "16000000 9000000 2000000 1900000"), ("claude.procs", "2 800000"),
        ("sshd.config", "readable"), ("sshd.maxsessions", "default"), ("fail2ban", "absent"),
        ("hooks.settings", "ok"), ("hooks.marker", "9"), ("skill.ports", "current"),
        ("projects.file", "ok"), ("projects.json", "valid"), ("projects.version", "1"),
        ("locale.avail", "yes"), ("locale.env", "yes"), ("locale.lang", "en_US.UTF-8"),
        ("done", "1"),
    ]
    lines.removeAll { removed.contains($0.0) }
    var output = lines.map { key, value in "\(key)=\(overrides[key] ?? value)" }
    for (key, value) in overrides where !lines.contains(where: { $0.0 == key }) { output.append("\(key)=\(value)") }
    return output.joined(separator: "\n") + "\n"
}

private func evaluate(
    _ overrides: [String: String] = [:], removing: Set<String> = [],
    hooksUpToDate: Bool? = true, skewSeconds: Double = 0
) -> [DoctorCheckID: DoctorCheck] {
    let facts = DoctorFacts.parse(sampleOutput(overriding: overrides, removing: removing))
    let device = Date(timeIntervalSince1970: 1_800_000_000 - skewSeconds)
    let context = DoctorEvaluator.Context(deviceNow: device, hooksUpToDate: hooksUpToDate)
    return Dictionary(uniqueKeysWithValues: DoctorEvaluator.evaluate(facts, context: context).map { ($0.id, $0) })
}

@Suite("DoctorFacts")
struct DoctorFactsTests {

    @Test("Ignora ruido, toma el primer valor y exige el final")
    func parse() {
        let facts = DoctorFacts.parse("Welcome to Ubuntu\nexport FOO=bar\nos=Linux\nos=Otro\nWARNING: x\nnota=dentro=igual\ndone=1\n")
        #expect(facts["os"] == "Linux")
        #expect(facts["nota"] == "dentro=igual")
        #expect(facts["FOO"] == nil)
        #expect(facts.isComplete)
        #expect(!DoctorFacts.parse("os=Linux\n").isComplete)
    }

    @Test("flag y numbers son estrictos")
    func typed() {
        let facts = DoctorFacts.parse("a=yes\nb=no\nc=quizas\nn=10 20\nbad=10 x\nneg=-1 2\nshort=10\nblank=   \n")
        #expect(facts.flag("a") == true)
        #expect(facts.flag("b") == false)
        #expect(facts.flag("c") == nil)
        #expect(facts.numbers("n", count: 2) == [10, 20])
        #expect(facts.numbers("bad", count: 2) == nil)
        #expect(facts.numbers("neg", count: 2) == nil)
        #expect(facts.numbers("short", count: 2) == nil)
        #expect(facts["blank"] == nil)
    }

    @Test("Versiones: extrae la primera secuencia y compara por partes")
    func versions() {
        #expect(DoctorVersion(parsing: "tmux 3.3a")?.parts == [3, 3])
        #expect(DoctorVersion(parsing: "git version 2.39.2 (Apple Git-143)")?.parts == [2, 39, 2])
        #expect(DoctorVersion(parsing: "tmux next-3.5")?.parts == [3, 5])
        #expect(DoctorVersion(parsing: "tmux master") == nil)
        #expect(DoctorVersion(2, 9) < DoctorVersion(2, 26))
        #expect(DoctorVersion(2, 26) == DoctorVersion(2, 26, 0))
        #expect(!(DoctorVersion(2, 26) < DoctorVersion(2, 26, 0)))
    }
}

@Suite("DoctorEvaluator")
struct DoctorEvaluatorTests {

    @Test("Un servidor sano no tiene avisos ni problemas")
    func healthy() {
        let checks = evaluate()
        #expect(checks.count == DoctorCheckID.allCases.count)
        let result = DoctorResult(checks: Array(checks.values), finishedAt: Date())
        #expect(result.overall == .ok, "\(result.checks.filter { $0.status != .ok })")
        #expect(result.summary == "Todo en orden.")
    }

    @Test("tmux: ausente es un problema con el comando del gestor; antiguo es aviso")
    func tmux() {
        let missing = evaluate(["tmux.present": "no", "pm": "dnf"])[.tmux]
        #expect(missing?.status == .problem)
        #expect(missing?.fix == .copyCommand("sudo dnf install -y tmux"))
        #expect(evaluate(["tmux.present": "no", "pm": ""])[.tmux]?.fix == nil)
        #expect(evaluate(["tmux.version": "tmux 2.8"])[.tmux]?.status == .warning)
        #expect(evaluate(["tmux.version": "tmux next-3.5"])[.tmux]?.status == .ok)
        #expect(evaluate(["tmux.version": "tmux master"])[.tmux]?.status == .ok)
    }

    @Test("git: aviso por debajo de 2.26 y si falta")
    func git() {
        #expect(evaluate(["git.version": "git version 2.25.1"])[.git]?.status == .warning)
        #expect(evaluate(["git.version": "git version 2.26.0"])[.git]?.status == .ok)
        #expect(evaluate(["git.version": "git version 1.8.3.1"])[.git]?.status == .warning)
        #expect(evaluate(["git.present": "no", "pm": "pacman"])[.git]?.fix == .copyCommand("sudo pacman -S --noconfirm git"))
        #expect(evaluate(["git.present": "no"])[.git]?.status == .warning)
    }

    @Test("claude y gh: instalado, con sesión, sin sesión, sin comprobar")
    func claudeAndGH() {
        #expect(evaluate()[.claude]?.status == .ok)
        #expect(evaluate(["claude.auth": "out"])[.claude]?.status == .warning)
        #expect(evaluate(["claude.auth": "unknown"])[.claude]?.status == .unknown)
        #expect(evaluate(["claude.present": "no"])[.claude]?.fix == .copyCommand(DoctorInstallHints.claudeInstall))
        #expect(evaluate(["gh.auth": "out"])[.gh]?.fix == .copyCommand("gh auth login"))
        #expect(evaluate(["gh.present": "no", "pm": "brew"])[.gh]?.fix == .copyCommand("brew install gh"))
        #expect(evaluate(["gh.auth": "unknown"])[.gh]?.status == .unknown)
    }

    @Test("Utilidades: lo que falta, con su consecuencia; python3 nunca es un fallo")
    func tools() {
        let missing = evaluate(["tool.findprintf": "no", "tool.timeout": "no"])[.tools]
        #expect(missing?.status == .warning)
        #expect(missing?.detail.contains("find con -printf") == true)
        #expect(missing?.detail.contains("Enviar al Mac") == true)
        #expect(evaluate(["os": "Darwin", "tool.findprintf": "no"])[.tools]?.fix == nil)
        #expect(evaluate(["tool.python3": "no"])[.python]?.status == .ok)
        let unknown = evaluate(removing: ["tool.timeout", "tool.cksum", "tool.base64d", "tool.mkfifo",
                                          "tool.nohup", "tool.findprintf", "tool.awk"])
        #expect(unknown[.tools]?.status == .unknown)
    }

    @Test("Disco: umbrales de aviso y problema")
    func disk() {
        #expect(evaluate(["disk.home": "100000000 900000"])[.diskHome]?.status == .warning)
        #expect(evaluate(["disk.home": "100000000 100000"])[.diskHome]?.status == .problem)
        #expect(evaluate(["disk.tmp": "1000000 100000"])[.diskTmp]?.status == .warning)
        #expect(evaluate(["disk.tmp": "1000000 40000"])[.diskTmp]?.status == .problem)
        #expect(evaluate(["disk.home": "basura"])[.diskHome]?.status == .unknown)
    }

    @Test("Memoria, swap y procesos de Claude")
    func memory() {
        #expect(evaluate(["mem": "16000000 800000 0 0"])[.memory]?.status == .warning)
        #expect(evaluate(["mem": "16000000 200000 0 0"])[.memory]?.status == .problem)
        #expect(evaluate(["mem": "2000000 1500000 0 0"])[.swap]?.status == .warning)       // sin swap, poca RAM
        #expect(evaluate(["mem": "16000000 9000000 0 0"])[.swap]?.status == .ok)           // sin swap, mucha RAM
        #expect(evaluate(["mem": "8000000 4000000 1000000 100000"])[.swap]?.status == .warning)
        #expect(evaluate(["claude.procs": "5 7000000"])[.claudeProcesses]?.status == .warning)   // 44 % de 16 GB
        #expect(evaluate(["claude.procs": "9 12000000"])[.claudeProcesses]?.status == .problem)
        #expect(evaluate(["claude.procs": "0 0"])[.claudeProcesses]?.status == .ok)
        let mac = evaluate(removing: ["mem"])
        #expect(mac[.memory]?.status == .unknown && mac[.swap]?.status == .unknown)
    }

    @Test("MaxSessions: aviso por debajo de 6, ilegible = no se pudo comprobar")
    func maxSessions() {
        #expect(evaluate()[.maxSessions]?.status == .ok)
        #expect(evaluate(["sshd.maxsessions": "4"])[.maxSessions]?.status == .warning)
        #expect(evaluate(["sshd.maxsessions": "6"])[.maxSessions]?.status == .ok)
        #expect(evaluate(["sshd.config": "unreadable"])[.maxSessions]?.status == .unknown)
        #expect(evaluate(["sshd.maxsessions": "muchas"])[.maxSessions]?.status == .unknown)
    }

    @Test("fail2ban es solo informativo")
    func fail2ban() {
        for state in ["running", "installed", "absent"] {
            #expect(evaluate(["fail2ban": state])[.fail2ban]?.status == .ok)
        }
    }

    @Test("Hooks de Claude: ausentes, desactualizados, al día")
    func hooks() {
        #expect(evaluate(["hooks.settings": "missing"])[.claudeHooks]?.fix == .installClaudeHooks(isUpdate: false))
        #expect(evaluate(["hooks.marker": "0"])[.claudeHooks]?.fix == .installClaudeHooks(isUpdate: false))
        #expect(evaluate(hooksUpToDate: false)[.claudeHooks]?.fix == .installClaudeHooks(isUpdate: true))
        #expect(evaluate(hooksUpToDate: true)[.claudeHooks]?.status == .ok)
        #expect(evaluate(hooksUpToDate: nil)[.claudeHooks]?.status == .ok)
        #expect(evaluate(["hooks.settings": "unreadable"])[.claudeHooks]?.status == .unknown)
    }

    @Test("Skill de puertos")
    func skill() {
        #expect(evaluate(["skill.ports": "missing"])[.portsSkill]?.fix == .installPortsSkill(isUpdate: false))
        #expect(evaluate(["skill.ports": "outdated"])[.portsSkill]?.fix == .installPortsSkill(isUpdate: true))
        #expect(evaluate()[.portsSkill]?.fix == nil)
    }

    @Test("projects.json: ausente es normal, inválido es un problema")
    func projects() {
        #expect(evaluate(["projects.file": "missing"])[.projectsFile]?.status == .ok)
        #expect(evaluate(["projects.json": "invalid"])[.projectsFile]?.status == .problem)
        #expect(evaluate(["projects.file": "unreadable"])[.projectsFile]?.status == .problem)
        #expect(evaluate()[.projectsFile]?.detail.contains("versión 1") == true)
    }

    @Test("Locale sin UTF-8 es un aviso con arreglo")
    func locale() {
        #expect(evaluate(["locale.env": "no", "locale.avail": "yes"])[.locale]?.status == .warning)
        #expect(evaluate(["locale.env": "no", "locale.avail": "no"])[.locale]?.fix != nil)
        #expect(evaluate(["locale.env": "no", "locale.avail": "unknown"])[.locale]?.status == .warning)
        #expect(evaluate(removing: ["locale.env"])[.locale]?.status == .unknown)
    }

    @Test("Reloj: aviso desde 1 min, problema desde 5; en ambos sentidos")
    func clock() {
        #expect(evaluate(skewSeconds: 5)[.clock]?.status == .ok)
        #expect(evaluate(skewSeconds: 90)[.clock]?.status == .warning)
        #expect(evaluate(skewSeconds: -90)[.clock]?.status == .warning)
        #expect(evaluate(skewSeconds: 400)[.clock]?.status == .problem)
        #expect(evaluate(["clock": "x"])[.clock]?.status == .unknown)
    }

    @Test("El resumen cuenta problemas y avisos")
    func summary() {
        let checks = [
            DoctorCheck(.tmux, "a", .problem, ""), DoctorCheck(.git, "b", .warning, ""),
            DoctorCheck(.gh, "c", .warning, ""), DoctorCheck(.claude, "d", .unknown, ""),
        ]
        let result = DoctorResult(checks: checks, finishedAt: Date())
        #expect(result.summary == "1 problema y 2 avisos.")
        #expect(result.overall == .problem)
        #expect(result.plainText(serverLabel: "servidor-1").contains("[Aviso] b"))
    }
}
