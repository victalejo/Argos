//
//  DiagnosticReportTests.swift
//  ArgosTests
//
//  «Copiar diagnóstico»: redacción (secretos siempre, datos personales por defecto),
//  formato y recorte del registro, y composición del informe.
//

import Foundation
import Testing
@testable import Argos

@Suite("DiagnosticRedactor")
struct DiagnosticRedactorTests {

    private let servers = [
        DiagnosticRedactor.KnownServer(name: "Producción", host: "prod.miempresa.com", username: "victor"),
        DiagnosticRedactor.KnownServer(name: "dev", host: "203.0.113.7", username: "root"),
    ]

    private func redact(_ text: String, known: Bool = true, personal: Bool = false) -> String {
        var redactor = DiagnosticRedactor(knownServers: known ? servers : [], includesPersonalData: personal)
        return redactor.redact(text)
    }

    @Test("Servidores conocidos: host y nombre comparten marcador estable")
    func knownServers() {
        let text = redact("Conectado a prod.miempresa.com (Producción); luego 203.0.113.7 y dev")
        #expect(text == "Conectado a servidor-1 (servidor-1); luego servidor-2 y servidor-2")
    }

    @Test("Un host más largo no queda a medias por otro más corto")
    func longestFirst() {
        var redactor = DiagnosticRedactor(knownServers: [
            .init(name: "a", host: "miempresa.com", username: "u"),
            .init(name: "b", host: "prod.miempresa.com", username: "u"),
        ])
        #expect(redactor.redact("prod.miempresa.com y miempresa.com") == "servidor-2 y servidor-1")
    }

    @Test("IPv4: se sustituyen y se conserva lo que no es una IP")
    func ipv4() {
        let text = redact("ip 192.168.1.20 y 10.0.0.5, otra vez 192.168.1.20; versión 15.4.1; 999.1.1.1; 1.2.3.4.5", known: false)
        #expect(text == "ip servidor-1 y servidor-2, otra vez servidor-1; versión 15.4.1; 999.1.1.1; 1.2.3.4.5")
    }

    @Test("IPv6: direcciones válidas sí; horas y MAC no")
    func ipv6() {
        let text = redact("v6 2001:db8::1 y fe80::1ff:fe23:4567:890a, hora 12:30:45, mac aa:bb:cc:dd:ee:ff, [::1]:22", known: false)
        #expect(text.contains("v6 servidor-1 y servidor-2"))
        #expect(text.contains("hora 12:30:45"))
        #expect(text.contains("mac aa:bb:cc:dd:ee:ff"))
        #expect(!text.contains("2001:db8"))
        #expect(!text.contains("fe80"))
        #expect(DiagnosticRedactor.isIPv6("::1"))
        #expect(!DiagnosticRedactor.isIPv6("12:30:45"))
    }

    @Test("usuario@host, también con IP y correos, con marcadores consistentes")
    func userAtHost() {
        let text = redact("ssh alice@build.example.org y alice@10.1.2.3; bob@build.example.org", known: false)
        #expect(text == "ssh usuario-1@servidor-1 y usuario-1@servidor-2; usuario-2@servidor-1")
        #expect(redact("victor@prod.miempresa.com") == "usuario-1@servidor-1")
    }

    @Test("Rutas /home/<usuario> y /Users/<usuario>")
    func homePaths() {
        let text = redact("abre /home/alice/proyecto y /Users/alice/Library, /home/bob/x", known: false)
        #expect(text == "abre /home/usuario-1/proyecto y /Users/usuario-1/Library, /home/usuario-2/x")
        #expect(redact("/Users/victor/Desktop") == "/Users/usuario-1/Desktop")
    }

    @Test("Secretos: claves, tokens y contraseñas se quitan SIEMPRE, incluso con datos personales")
    func secrets() {
        let input = """
        key /Users/alice/.ssh/id_ed25519 y ~/.ssh/config y /srv/keys/deploy.pem y /home/bob/id_rsa.pub
        token sk-ant-api03-AbCdEfGhIjKlMnOp y ghp_abcdefghijklmnop1234 y github_pat_11ABCDEFGHIJKLMNOP
        CLAUDE_CODE_OAUTH_TOKEN=abc123 password: "hunter 2" passphrase=secreta
        Authorization: Bearer eyJhbGciOi.payload.firma
        """
        for personal in [false, true] {
            let text = redact(input, known: false, personal: personal)
            for leaked in ["id_ed25519", ".ssh/config", "deploy.pem", "id_rsa", "AbCdEfGh", "ghp_abc", "github_pat_11",
                           "abc123", "hunter", "secreta", "eyJhbGciOi"] {
                #expect(!text.contains(leaked), "filtró \(leaked) (personal=\(personal))")
            }
            #expect(text.contains(DiagnosticRedactor.keyPathMarker))
        }
    }

    @Test("Con datos personales incluidos se respetan hosts, IPs y usuarios")
    func personalDataIncluded() {
        let text = redact("alice@203.0.113.7 /home/alice", personal: true)
        #expect(text == "alice@203.0.113.7 /home/alice")
    }

    @Test("Texto normal no se toca")
    func untouched() {
        let line = "10:42:11.123 [notice] ssh: Canal rechazado (intento 2); versión 1.8.10 build 63"
        #expect(redact(line, known: false) == line)
    }

    @Test("La etiqueta del servidor del encabezado se redacta igual que el resto")
    func label() {
        var redactor = DiagnosticRedactor(knownServers: servers)
        #expect(redactor.serverLabel("Producción") == "servidor-1")
        var open = DiagnosticRedactor(knownServers: servers, includesPersonalData: true)
        #expect(open.serverLabel("Producción") == "Producción")
    }
}

@Suite("DiagnosticReport")
struct DiagnosticReportTests {

    private let app = DiagnosticAppInfo(
        version: "1.9.0", build: "64", variant: "GitHub (Sparkle)", system: "macOS 15.4", deviceModel: "Mac14,2"
    )

    private func input(log: DiagnosticLogExcerpt, doctor: DoctorResult? = nil) -> DiagnosticInput {
        DiagnosticInput(app: app, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        serverName: "Producción", doctor: doctor, log: log)
    }

    @Test("Cabecera con versión, variante, sistema y modelo")
    func header() {
        var redactor = DiagnosticRedactor()
        let text = DiagnosticReport.compose(input(log: .lines([], truncated: false)), redactor: &redactor)
        #expect(text.contains("Versión: 1.9.0 (build 64)"))
        #expect(text.contains("Variante: GitHub (Sparkle)"))
        #expect(text.contains("Sistema: macOS 15.4"))
        #expect(text.contains("Dispositivo: Mac14,2"))
        #expect(text.contains("Datos personales: ocultos"))
        #expect(text.contains("Sin servidor conectado"))
    }

    @Test("El Doctor y el registro salen redactados con los mismos marcadores")
    func redactsSections() {
        let doctor = DoctorResult(
            checks: [DoctorCheck(.clock, "Reloj del servidor", .warning, "Desfase en 203.0.113.7", fix: .copyCommand("ssh root@203.0.113.7"))],
            finishedAt: Date()
        )
        let log = DiagnosticLogExcerpt.lines(["10:00:00.000 [error] ssh: fallo con victor@prod.miempresa.com"], truncated: false)
        var redactor = DiagnosticRedactor(knownServers: [.init(name: "Producción", host: "prod.miempresa.com", username: "victor")])
        let text = DiagnosticReport.compose(input(log: log, doctor: doctor), redactor: &redactor)
        #expect(text.contains("Doctor del servidor: servidor-1"))
        #expect(text.contains("Desfase en servidor-2"))
        #expect(text.contains("usuario-2@servidor-2") || text.contains("usuario-1@servidor-2"))
        #expect(text.contains("fallo con usuario-1@servidor-1"))
        #expect(!text.contains("203.0.113.7"))
        #expect(!text.contains("prod.miempresa.com"))
    }

    @Test("Sin registro disponible, el informe se genera y lo dice")
    func logUnavailable() {
        var redactor = DiagnosticRedactor()
        let text = DiagnosticReport.compose(input(log: .unavailable("sin permisos")), redactor: &redactor)
        #expect(text.contains("## Registro de la app"))
        #expect(text.contains("No disponible"))
        #expect(text.contains("sin permisos"))
        #expect(text.contains("Versión: 1.9.0"))
    }

    @Test("Un secreto en el registro no sale ni con datos personales incluidos")
    func secretInLog() {
        let log = DiagnosticLogExcerpt.lines(["x [error] agent: token=sk-ant-oat01-ZZZZZZZZZZZZ en /Users/a/.ssh/id_rsa"], truncated: false)
        var redactor = DiagnosticRedactor(includesPersonalData: true)
        let text = DiagnosticReport.compose(input(log: log), redactor: &redactor)
        #expect(!text.contains("ZZZZ"))
        #expect(!text.contains("id_rsa"))
        #expect(text.contains("incluidos a petición"))
    }
}

@Suite("DiagnosticLogFormatter")
struct DiagnosticLogFormatterTests {

    private func line(_ seconds: Double, _ message: String) -> DiagnosticLogLine {
        DiagnosticLogLine(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), level: "error", category: "ssh", message: message)
    }

    @Test("Formato de una línea y saltos de línea aplanados")
    func format() {
        let text = DiagnosticLogFormatter.format(line(0, "a\nb"))
        #expect(text.hasSuffix("[error] ssh: a ⏎ b"))
        #expect(text.hasPrefix("08:00:00.000"))   // 1 800 000 000 s = 08:00:00 UTC
    }

    @Test("Tope de tamaño: se quedan las líneas más recientes, en orden")
    func truncation() {
        let lines = (0..<10).map { line(Double($0), "mensaje número \($0)") }
        guard case .lines(let kept, let truncated) = DiagnosticLogFormatter.excerpt(from: lines.shuffled(), maxBytes: 200) else {
            Issue.record("debía haber líneas"); return
        }
        #expect(truncated)
        #expect(kept.count < 10 && !kept.isEmpty)
        #expect(kept.last?.hasSuffix("mensaje número 9") == true)
        #expect(kept == kept.sorted())
        #expect(kept.reduce(0) { $0 + $1.utf8.count + 1 } <= 200)
    }

    @Test("Sin recorte cuando cabe todo")
    func noTruncation() {
        guard case .lines(let kept, let truncated) = DiagnosticLogFormatter.excerpt(from: [line(1, "x"), line(0, "y")]) else {
            Issue.record("debía haber líneas"); return
        }
        #expect(!truncated && kept.count == 2)
        #expect(kept[0].hasSuffix("y"))
    }

    @Test("El lector real nunca lanza: devuelve líneas o «no disponible»")
    func readerNeverThrows() async {
        let excerpt = await DiagnosticLogReader.read(minutes: 1)
        switch excerpt {
        case .lines, .unavailable: break
        }
    }
}
