//
//  DoctorScriptTests.swift
//  ArgosTests
//
//  El comando remoto del Doctor se EJECUTA de verdad con `/bin/sh` (y con dash, si existe) y
//  un HOME temporal: debe terminar con 0, no escribir nada y producir una salida que el
//  parser entienda y que las reglas evalúen sin sorpresas. También prueba `DoctorModel` con
//  el mock de SSH.
//

import Foundation
import Testing
@testable import Argos

@Suite("DoctorScript", .serialized)
struct DoctorScriptTests {

    /// Casa temporal con la forma de un servidor con Argos: settings de Claude, skill y projects.json.
    private func makeHome(settings: String? = nil, projects: String? = nil, skillVersion: String? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let settings {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try settings.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        }
        if let projects {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/argos"), withIntermediateDirectories: true)
            try projects.write(to: home.appendingPathComponent(".config/argos/projects.json"), atomically: true, encoding: .utf8)
        }
        if let skillVersion {
            let dir = home.appendingPathComponent(".claude/skills/argos-puertos")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "# \(skillVersion)\n".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "#!/bin/sh\n# \(skillVersion)\n".write(to: dir.appendingPathComponent("argos-ports"), atomically: true, encoding: .utf8)
        }
        return home
    }

    /// Ejecuta el script como `sshd` (`sh -c`), con PATH mínimo más `extraPath` para stubs.
    private func run(
        shell: String = "/bin/sh", home: URL, extraPath: String? = nil, script: String = DoctorScript.command
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        let path = [extraPath, "/usr/bin:/bin:/usr/sbin:/sbin"].compactMap { $0 }.joined(separator: ":")
        process.environment = ["HOME": home.path, "PATH": path, "SHELL": "/bin/sh", "LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Rutas (relativas) de todo lo que hay en `root`: dicen QUÉ apareció si algo se escribe.
    private func tree(_ root: URL) -> Set<String> {
        let paths = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        return Set(paths)
    }

    /// Solo la búsqueda de `claude` del Doctor por los shells de login (`"$s" -lc`): lo que
    /// crean los perfiles del sistema por sí solos no es del Doctor.
    private static let baselineScript = "for s in \"$SHELL\" bash zsh sh; do [ -n \"$s\" ] || continue; "
        + "\"$s\" -lc 'command -v claude' >/dev/null 2>&1 </dev/null; done; exit 0"

    private func loginBaseline(shell: String, extraPath: String? = nil) throws -> Set<String> {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try run(shell: shell, home: home, extraPath: extraPath, script: Self.baselineScript)
        return tree(home)
    }

    /// El Doctor no añade nada al HOME más allá de lo que hacen los perfiles de login.
    private func expectNothingWritten(_ home: URL, baseline: Set<String>, _ shell: String) {
        let created = tree(home)
        let owned = created.filter { $0.hasPrefix(".config/argos") || $0.hasPrefix(".claude") || $0.hasPrefix(".config/gh") }
        #expect(owned.isEmpty, "\(shell) creó en HOME rutas de Argos, Claude o gh: \(owned.sorted())")
        let extra = created.subtracting(baseline)
        #expect(extra.isEmpty, "\(shell) escribió en HOME: \(extra.sorted()) (los perfiles de login solos crean: \(baseline.sorted()))")
    }

    private var shells: [String] {
        ["/bin/sh", "/bin/dash", "/bin/bash"].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test("Termina con 0, completo, y con las claves esperadas en cada shell POSIX")
    func runsEverywhere() throws {
        for shell in shells {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let baseline = try loginBaseline(shell: shell)
            let (status, output) = try run(shell: shell, home: home)
            #expect(status == 0, "\(shell)")
            let facts = DoctorFacts.parse(output)
            #expect(facts.isComplete, "\(shell): \(output)")
            #expect(facts["os"] == "Darwin", "\(shell)")
            #expect(facts["tmux.present"] != nil && facts["git.present"] != nil)
            #expect(facts["claude.present"] == "no")
            #expect(facts["gh.present"] == "no")
            #expect(facts.numbers("disk.home", count: 2) != nil, "\(shell): \(output)")
            #expect(facts.numbers("disk.tmp", count: 2) != nil)
            #expect(facts["tool.awk"] == "yes")
            #expect(facts["tool.base64d"] == "yes")
            #expect(facts["tool.findprintf"] == "no")          // find de BSD
            #expect(facts["hooks.settings"] == "missing")
            #expect(facts["skill.ports"] == "missing")
            #expect(facts["projects.file"] == "missing")
            #expect(facts["locale.env"] == "yes")
            #expect(Int(facts["clock"] ?? "") ?? 0 > 1_700_000_000)
            // Todo el script es de solo lectura: no añade nada al HOME temporal.
            expectNothingWritten(home, baseline: baseline, shell)
        }
    }

    @Test("Con el gh REAL de la máquina tampoco escribe en HOME (se salta si no hay gh)")
    func realGHWritesNothing() throws {
        let found = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
            FileManager.default.isExecutableFile(atPath: "\($0)/gh")
        }
        guard let directory = found else { return }
        for shell in shells {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let baseline = try loginBaseline(shell: shell, extraPath: directory)
            let (status, output) = try run(shell: shell, home: home, extraPath: directory)
            #expect(status == 0)
            #expect(DoctorFacts.parse(output)["gh.present"] == "yes", "\(shell): \(output)")
            expectNothingWritten(home, baseline: baseline, shell)
        }
    }

    @Test("Lee settings, skill y projects.json del HOME")
    func readsHome() throws {
        let settings = "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"command\": \"x # \(ClaudeHookInstaller.marker)\"}]}]}}"
        let home = try makeHome(settings: settings, projects: "{\"version\": 3, \"projects\": []}",
                                skillVersion: PortForwardServerFiles.toolVersion)
        defer { try? FileManager.default.removeItem(at: home) }
        let facts = DoctorFacts.parse(try run(home: home).output)
        #expect(facts["hooks.settings"] == "ok")
        #expect(Int(facts["hooks.marker"] ?? "") == 1)
        #expect(facts["skill.ports"] == "current")
        #expect(facts["projects.file"] == "ok")
        #expect(facts["projects.version"] == "3")
        #expect(facts["projects.json"] == "valid")
    }

    @Test("Skill antigua, projects.json roto y settings sin hooks de Argos")
    func detectsProblems() throws {
        let home = try makeHome(settings: "{}", projects: "{ no es json", skillVersion: "argos-ports v1")
        defer { try? FileManager.default.removeItem(at: home) }
        let facts = DoctorFacts.parse(try run(home: home).output)
        #expect(facts["skill.ports"] == "outdated")
        #expect(facts["projects.json"] == "invalid")
        #expect(Int(facts["hooks.marker"] ?? "") == 0)
        let checks = DoctorEvaluator.evaluate(facts, context: .init())
        #expect(checks.first { $0.id == .projectsFile }?.status == .problem)
        #expect(checks.first { $0.id == .portsSkill }?.fix == .installPortsSkill(isUpdate: true))
        #expect(checks.first { $0.id == .claudeHooks }?.fix == .installClaudeHooks(isUpdate: false))
    }

    @Test("claude y gh con sesión y sin ella (stubs en el PATH)")
    func claudeAndGHStubs() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // Anotan (fuera del HOME) con qué carpeta de configuración corren; gh la crea, como el real.
        try stub("claude", "printf '%s\\n' \"${CLAUDE_CONFIG_DIR:-}\" >> '\(bin.path)/claude.dirs'\n"
            + "case \"$1\" in --version) echo '2.1.5 (Claude Code)';; auth) echo '{\"loggedIn\": true, \"email\": \"yo@example.com\"}';; esac")
        try stub("gh", "printf '%s|%s\\n' \"${GH_CONFIG_DIR:-}\" \"${GH_NO_UPDATE_NOTIFIER:-}\" >> '\(bin.path)/gh.dirs'\n"
            + "if [ -n \"$GH_CONFIG_DIR\" ]; then mkdir -p \"$GH_CONFIG_DIR\" && : > \"$GH_CONFIG_DIR/config.yml\"; fi\n"
            + "case \"$1\" in --version) echo 'gh version 2.45.0 (2024-03-01)';; auth) echo 'You are not logged into any GitHub hosts. Run gh auth login' >&2; exit 1;; esac")
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let baseline = try loginBaseline(shell: "/bin/sh", extraPath: bin.path)
        let output = try run(home: home, extraPath: bin.path).output
        expectNothingWritten(home, baseline: baseline, "/bin/sh")
        // Sin configuración propia, claude y gh la reciben en una carpeta temporal FUERA del
        // HOME (gh, sin avisos de actualización) que el Doctor borra al terminar.
        let claudeDirs = (try? String(contentsOf: bin.appendingPathComponent("claude.dirs"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let ghLines = (try? String(contentsOf: bin.appendingPathComponent("gh.dirs"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        #expect(!claudeDirs.isEmpty && !ghLines.isEmpty)
        for dir in claudeDirs + ghLines.map({ String($0.prefix { $0 != "|" }) }) {
            #expect(!dir.isEmpty && !dir.hasPrefix(home.path) && !FileManager.default.fileExists(atPath: dir), "carpeta de config: «\(dir)»")
        }
        #expect(ghLines.allSatisfy { $0.hasSuffix("|1") }, "gh sin GH_NO_UPDATE_NOTIFIER: \(ghLines)")
        let facts = DoctorFacts.parse(output)
        #expect(facts["claude.present"] == "yes")
        #expect(facts["claude.auth"] == "in")
        #expect(DoctorVersion(parsing: facts["claude.version"] ?? "")?.parts == [2, 1, 5])
        #expect(facts["gh.present"] == "yes")
        #expect(facts["gh.auth"] == "out")
        #expect(!output.contains("example.com"), "el correo no debe salir del servidor")
    }

    @Test("Valores raros no rompen el formato (una línea por clave)")
    func weirdValues() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-weird-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let url = bin.appendingPathComponent("tmux")
        try "#!/bin/sh\nprintf 'tmux 3.4\\tcon=tab y \\r retorno\\n'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try run(home: home, extraPath: bin.path).output
        let facts = DoctorFacts.parse(output)
        #expect(facts.isComplete)
        #expect(facts["tmux.version"]?.hasPrefix("tmux 3.4 con=tab") == true)
        #expect(!output.contains("\t") && !output.contains("\r"))
    }

    @Test("Un fallo del servidor devuelve una pantalla de error, no un resultado falso")
    @MainActor
    func modelIncompleteOutput() async {
        let mock = MockSSHService()
        mock.agentScriptOutput = { _ in "Last login: hoy\nos=Linux\n" }   // cortado: sin «done=1»
        let model = DoctorModel(service: mock, serverName: "dev")
        await model.run()
        guard case .failed(let message) = model.state else { Issue.record("debía fallar: \(model.state)"); return }
        #expect(message.contains("comprobación completa"))
    }

    @Test("El modelo evalúa, consulta los hooks y aplica un arreglo de un toque")
    @MainActor
    func modelRunAndFix() async {
        let mock = MockSSHService()
        var output = DoctorFacts.sampleHealthyOutput
        mock.agentScriptOutput = { command in
            command == DoctorScript.command ? output : ""
        }
        let model = DoctorModel(service: mock, serverName: "dev")
        await model.run()
        #expect(model.result?.checks.first { $0.id == .claudeHooks }?.status == .warning)   // el mock dice «no al día»
        #expect(model.result?.checks.first { $0.id == .claudeHooks }?.fix == .installClaudeHooks(isUpdate: true))

        output = output.replacingOccurrences(of: "skill.ports=current", with: "skill.ports=missing")
        await model.run()
        #expect(model.result?.checks.first { $0.id == .portsSkill }?.fix == .installPortsSkill(isUpdate: false))
        await model.apply(.installPortsSkill(isUpdate: false), to: .portsSkill)
        #expect(mock.agentScripts.contains(PortForwardServerFiles.installCommand))
        #expect(model.fixError == nil)
    }
}

extension DoctorFacts {
    /// Salida sana mínima para los tests del modelo.
    static let sampleHealthyOutput = """
    os=Linux
    clock=1800000000
    tmux.present=yes
    tmux.version=tmux 3.3a
    git.present=yes
    git.version=git version 2.43.0
    hooks.settings=ok
    hooks.marker=9
    skill.ports=current
    done=1

    """
}
