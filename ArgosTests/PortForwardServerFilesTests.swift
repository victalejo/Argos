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

    @Test("Claude pide con argos-ports open, Argos lo lista y lo retira (sh real)")
    func requestsEndToEnd() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("argos-req-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try run(PortForwardServerFiles.installCommand, home: home).status == 0)
        let script = home.appendingPathComponent(".claude/skills/argos-puertos/argos-ports").path

        // Validación del puerto.
        #expect(try run("\(script) open", home: home).status == 2)
        #expect(try run("\(script) open 70000", home: home).status == 2)
        #expect(try run("\(script) open 80a", home: home).status == 2)

        // Pedidos con nota (tabuladores y saltos se aplanan).
        let asked = try run("\(script) open 5173 'La web\tde\ninventario'", home: home)
        #expect(asked.status == 0)
        #expect(asked.output.contains("Claude quiere mostrarte el puerto 5173"))
        #expect(try run("\(script) open 8080", home: home).status == 0)

        var requests = PortForwardRequestParser.parse(try run(PortForwardServerFiles.listRequestsCommand, home: home).output)
        #expect(requests.map(\.port).sorted() == [5173, 8080])
        #expect(requests.first { $0.port == 5173 }?.note == "La web de inventario")
        #expect(requests.first { $0.port == 8080 }?.note == "")
        let listing = try run(script, home: home).output
        #expect(listing.contains("puerto 5173 - La web de inventario"))

        // Retirar uno.
        #expect(try run(PortForwardServerFiles.dismissRequestCommand(port: 5173), home: home).status == 0)
        requests = PortForwardRequestParser.parse(try run(PortForwardServerFiles.listRequestsCommand, home: home).output)
        #expect(requests.map(\.port) == [8080])
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

@Suite("PortForwardRequests")
struct PortForwardRequestTests {

    @Test("Parser: hora del servidor, caducadas fuera, más antiguas primero")
    func parser() {
        let output = "1000\n5173\t990\tLa web\n3000\t300\tvieja\n8080\t950\t\n99999\t990\tmal\nbasura\n4000\t995\n"
        let requests = PortForwardRequestParser.parse(output)
        #expect(requests.map(\.port) == [8080, 5173, 4000])
        #expect(requests[0].ageSeconds == 50)
        #expect(requests[1].note == "La web")
        #expect(requests[2].note == "")
        #expect(PortForwardRequestParser.parse("").isEmpty)
    }

    @Test("Mensaje del aviso con y sin nota")
    func prompt() {
        let withNote = PortForwardRequest(port: 5173, note: "La web", ageSeconds: 0)
        #expect(PortForwardRequestsModel.title(for: withNote) == "Claude quiere mostrarte el puerto 5173")
        #expect(PortForwardRequestPrompt.message(for: withNote, serverName: "dev").hasPrefix("«La web»"))
        let plain = PortForwardRequest(port: 80, note: "", ageSeconds: 0)
        #expect(PortForwardRequestPrompt.message(for: plain, serverName: "dev").hasPrefix("Se abrirá un túnel desde dev"))
    }

    @MainActor
    @Test("Aceptar abre el túnel, retira la solicitud y devuelve la URL")
    func accept() async {
        let mock = MockSSHService()
        mock.portRequests = [PortForwardRequest(port: 5173, note: "web", ageSeconds: 5),
                             PortForwardRequest(port: 8080, note: "", ageSeconds: 1)]
        let model = PortForwardRequestsModel(service: mock)
        await model.refresh()
        #expect(model.current?.port == 5173)
        let url = await model.accept()
        #expect(url?.absoluteString == "http://localhost:5173")
        #expect(mock.dismissedPortRequests == [5173])
        #expect(mock.forwards.map(\.remotePort) == [5173])
        await model.refresh()
        #expect(model.current?.port == 8080)
    }

    @MainActor
    @Test("Rechazar no abre nada y no vuelve a mostrarla aunque siga en el servidor")
    func decline() async {
        let mock = MockSSHService()
        mock.portRequests = [PortForwardRequest(port: 3000, note: "", ageSeconds: 1)]
        let model = PortForwardRequestsModel(service: mock)
        await model.refresh()
        await model.decline()
        #expect(mock.forwards.isEmpty)
        #expect(mock.dismissedPortRequests == [3000])
        mock.portRequests = [PortForwardRequest(port: 3000, note: "", ageSeconds: 2)]   // borrado aún no visto
        await model.refresh()
        #expect(model.current == nil)
    }

    @MainActor
    @Test("Si ya estaba reenviado, aceptar solo abre la URL existente")
    func alreadyForwarded() async throws {
        let mock = MockSSHService()
        let existing = try await mock.startPortForward(remotePort: 3000, targetHost: "localhost", preferredLocalPort: 3001)
        mock.portRequests = [PortForwardRequest(port: 3000, note: "", ageSeconds: 1)]
        let model = PortForwardRequestsModel(service: mock)
        await model.refresh()
        #expect(await model.accept() == existing.localURL)
        #expect(mock.forwards.count == 1)
    }

    @MainActor
    @Test("Un fallo al abrir se muestra")
    func failure() async {
        let mock = MockSSHService()
        mock.forwardError = PortForwardError.bindFailed("ocupado")
        mock.portRequests = [PortForwardRequest(port: 3000, note: "", ageSeconds: 1)]
        let model = PortForwardRequestsModel(service: mock)
        await model.refresh()
        #expect(await model.accept() == nil)
        #expect(model.errorMessage?.contains("ocupado") == true)
    }
}
