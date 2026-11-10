//
//  PortForwardServerFilesTests.swift
//  ArgosTests
//
//  Cierre por inactividad y archivos que Argos deja en el servidor para la skill de Claude.
//  Los comandos se EJECUTAN con /bin/sh y un HOME temporal: instalación idempotente,
//  publicación, script `argos-ports` y borrado.
//

import Foundation
import Testing
@testable import Argos

@Suite("PortForwardIdlePolicy")
struct PortForwardIdlePolicyTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Cierra solo sin conexiones y pasado el límite")
    func shouldClose() {
        let later = start.addingTimeInterval(15 * 60)
        #expect(PortForwardIdlePolicy.shouldClose(activeConnections: 0, lastActivity: start, now: later, limitMinutes: 15))
        #expect(!PortForwardIdlePolicy.shouldClose(activeConnections: 0, lastActivity: start, now: later.addingTimeInterval(-1), limitMinutes: 15))
        #expect(!PortForwardIdlePolicy.shouldClose(activeConnections: 1, lastActivity: start, now: later.addingTimeInterval(3600), limitMinutes: 15))
        #expect(!PortForwardIdlePolicy.shouldClose(activeConnections: 0, lastActivity: start, now: later.addingTimeInterval(86_400), limitMinutes: 0))
    }

    @Test("La actividad cuenta conexiones y su última hora")
    func activity() {
        let activity = PortForwardActivity(now: start)
        activity.connectionOpened(now: start.addingTimeInterval(10))
        activity.connectionOpened(now: start.addingTimeInterval(20))
        activity.connectionClosed(now: start.addingTimeInterval(30))
        #expect(activity.snapshot.active == 1)
        activity.connectionClosed(now: start.addingTimeInterval(40))
        activity.connectionClosed(now: start.addingTimeInterval(50))   // nunca negativo
        #expect(activity.snapshot.active == 0)
        #expect(activity.snapshot.lastActivity == start.addingTimeInterval(50))
    }

    @Test("Etiquetas del selector")
    func labels() {
        #expect(PortForwardIdlePolicy.label(minutes: 0) == "Nunca")
        #expect(PortForwardIdlePolicy.label(minutes: 15) == "15 min")
        #expect(PortForwardIdlePolicy.options.contains(PortForwardIdlePolicy.defaultMinutes))
    }
}

@Suite("PortForwardServerFiles", .serialized)
struct PortForwardServerFilesTests {

    private let forwards = [
        ActivePortForward(id: UUID(), remotePort: 5173, targetHost: "localhost", localPort: 5173),
        ActivePortForward(id: UUID(), remotePort: 3000, targetHost: "localhost", localPort: 3001),
    ]

    @Test("El id del dispositivo solo admite caracteres seguros")
    func safeID() {
        #expect(PortForwardServerFiles.safeID("AB-12") == "AB-12")
        #expect(PortForwardServerFiles.safeID("../../etc/passwd") == "etcpasswd")
        #expect(PortForwardServerFiles.safeID("ñ;rm") == "rm")
        #expect(PortForwardServerFiles.safeID("") == "dispositivo")
    }

    @Test("Líneas ordenadas por puerto y sin tabuladores colados")
    func lines() {
        #expect(PortForwardServerFiles.forwardLines(forwards) == "3000\t3001\tlocalhost\n5173\t5173\tlocalhost\n")
    }

    @Test("Instala, publica, lista y borra de verdad con sh")
    func endToEnd() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("argos-ports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Un script de la v1 (fuera de la skill) se borra al instalar.
        let oldScript = home.appendingPathComponent(".config/argos/bin/argos-ports")
        try FileManager.default.createDirectory(at: oldScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# argos-ports v1".write(to: oldScript, atomically: true, encoding: .utf8)

        // Instalación (y una segunda vez: idempotente, no reescribe).
        #expect(try run(PortForwardServerFiles.installCommand, home: home).status == 0)
        #expect(!FileManager.default.fileExists(atPath: oldScript.path))
        let script = home.appendingPathComponent(".claude/skills/argos-puertos/argos-ports")
        let skill = home.appendingPathComponent(".claude/skills/argos-puertos/SKILL.md")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        let skillText = try String(contentsOf: skill, encoding: .utf8)
        #expect(skillText.hasPrefix("---\nname: argos-puertos\n"))
        #expect(skillText.contains(PortForwardServerFiles.toolVersion))
        let before = try FileManager.default.attributesOfItem(atPath: script.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        #expect(try run(PortForwardServerFiles.installCommand, home: home).status == 0)
        let after = try FileManager.default.attributesOfItem(atPath: script.path)[.modificationDate] as? Date
        #expect(before == after)

        // Publicación con un nombre con comillas y tabulador (no rompe el formato).
        let publish = PortForwardServerFiles.publishCommand(
            deviceID: "DEV-1", deviceName: "Mac de O'Brien\tpro", forwards: forwards
        )
        #expect(try run(publish, home: home).status == 0)
        let output = try run(script.path, home: home).output
        #expect(output.contains("Reenviados por Argos"))
        #expect(output.contains("- Mac de O'Brien pro"))
        #expect(output.contains("puerto 3000 del servidor -> http://localhost:3001 en ese dispositivo"))
        #expect(output.contains("puerto 5173 del servidor -> http://localhost:5173"))
        #expect(!output.contains("sin noticias"))

        // Entrada antigua: el script la marca como dudosa.
        let file = home.appendingPathComponent(".config/argos/forwards/DEV-1.tsv")
        let old = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: #"\t\d+\n"#, with: "\t1000\n", options: .regularExpression, range: nil)
        try old.write(to: file, atomically: true, encoding: .utf8)
        #expect(try run(script.path, home: home).output.contains("sin noticias de Argos"))

        // Borrado.
        #expect(try run(PortForwardServerFiles.unpublishCommand(deviceID: "DEV-1"), home: home).status == 0)
        #expect(try run(script.path, home: home).output.contains("(ninguno: el usuario puede abrir uno desde Argos -> Puertos)"))
    }

    /// Ejecuta `command` como lo haría sshd (`/bin/sh -c`) con `HOME` aislado.
    private func run(_ command: String, home: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
