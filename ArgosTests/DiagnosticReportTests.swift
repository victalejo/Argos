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

    private func logEntry(_ message: String, level: String = "error", category: String = "ssh", at seconds: Double = 0) -> DiagnosticLogLine {
        DiagnosticLogLine(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), level: level, category: category, message: message)
    }

    private func input(log: DiagnosticLogExcerpt, doctor: DoctorResult? = nil) -> DiagnosticInput {
        DiagnosticInput(app: app, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        serverName: "Producción", doctor: doctor, log: log)
    }

    @Test("Cabecera con versión, variante, sistema y modelo")
    func header() {
        var redactor = DiagnosticRedactor()
        let text = DiagnosticReport.compose(input(log: .entries([])), redactor: &redactor)
        #expect(text.contains("Versión: 1.9.0 (build 64)"))
        #expect(text.contains("Variante: GitHub (Sparkle)"))
        #expect(text.contains("Sistema: macOS 15.4"))
        #expect(text.contains("Dispositivo: Mac14,2"))
        #expect(text.contains("Datos personales: ocultos"))
        #expect(text.contains("Sin servidor conectado"))
        #expect(text.contains("Revisa este texto antes de publicarlo"))
    }

    @Test("El Doctor y el registro salen redactados con los mismos marcadores")
    func redactsSections() {
        let doctor = DoctorResult(
            checks: [DoctorCheck(.clock, "Reloj del servidor", .warning, "Desfase en 203.0.113.7", fix: .copyCommand("ssh root@203.0.113.7"))],
            finishedAt: Date()
        )
        let log = DiagnosticLogExcerpt.entries([logEntry("fallo con victor@prod.miempresa.com")])
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
        let log = DiagnosticLogExcerpt.entries([logEntry("token=sk-ant-oat01-ZZZZZZZZZZZZ en /Users/a/.ssh/id_rsa")])
        var redactor = DiagnosticRedactor(includesPersonalData: true)
        let text = DiagnosticReport.compose(input(log: log), redactor: &redactor)
        #expect(!text.contains("ZZZZ"))
        #expect(!text.contains("id_rsa"))
        #expect(text.contains("incluidos a petición"))
    }
}

@Suite("DiagnosticLogFormatter")
struct DiagnosticLogFormatterTests {

    private func line(_ seconds: Double, _ message: String, level: String = "error", category: String = "ssh") -> DiagnosticLogLine {
        DiagnosticLogLine(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), level: level, category: category, message: message)
    }

    @Test("Formato de una línea y saltos de línea aplanados")
    func format() {
        let text = DiagnosticLogFormatter.format(line(0, "a\nb"))
        #expect(text.hasSuffix("[error] ssh: a ⏎ b"))
        #expect(text.hasPrefix("08:00:00.000"))   // 1 800 000 000 s = 08:00:00 UTC
    }

    @Test("Tope de tamaño: se quedan las líneas más recientes, en orden")
    func truncation() {
        let lines = (0..<10).map { "línea \($0) con relleno" }
        let (kept, truncated) = DiagnosticLogFormatter.newest(of: lines, maxBytes: 100)
        #expect(truncated)
        #expect(!kept.isEmpty && kept.count < 10)
        #expect(kept.last == "línea 9 con relleno")
        #expect(kept.reduce(0) { $0 + $1.utf8.count + 1 } <= 100)
        let all = DiagnosticLogFormatter.newest(of: lines, maxBytes: 10_000)
        #expect(!all.truncated && all.lines == lines)
    }

    @Test("Una línea enorme se recorta con aviso")
    func clip() {
        let clipped = DiagnosticLogFormatter.clip(String(repeating: "x", count: 5_000), to: 600)
        #expect(clipped.count < 700 && clipped.hasSuffix("[recortado]"))
        #expect(DiagnosticLogFormatter.clip("corta", to: 600) == "corta")
    }

    @Test("Por defecto no entran las entradas debug ni la categoría del agente")
    func policy() {
        let policy = DiagnosticLogPolicy()
        #expect(policy.admits(line(0, "x", level: "error", category: "ssh")))
        #expect(!policy.admits(line(0, "x", level: "debug", category: "ssh")))
        #expect(!policy.admits(line(0, "x", level: "error", category: "agent")))
        #expect(DiagnosticLogPolicy(includesTechnicalDetail: true).admits(line(0, "x", level: "debug", category: "agent")))
    }

    @Test("El lector real nunca lanza: devuelve entradas o «no disponible»")
    func readerNeverThrows() async {
        switch await DiagnosticLogReader.read(minutes: 1) {
        case .entries, .unavailable: break
        }
    }
}

@Suite("DiagnosticReport: filtrado y recorte del registro")
struct DiagnosticReportLogTests {

    private func entry(_ message: String, level: String = "error", category: String = "ssh", at seconds: Double = 0) -> DiagnosticLogLine {
        DiagnosticLogLine(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), level: level, category: category, message: message)
    }

    private func compose(_ lines: [DiagnosticLogLine], policy: DiagnosticLogPolicy = .init(), personal: Bool = false) -> String {
        let app = DiagnosticAppInfo(version: "1", build: "1", variant: "v", system: "s", deviceModel: "m")
        let input = DiagnosticInput(app: app, generatedAt: Date(timeIntervalSince1970: 0), serverName: nil, doctor: nil, log: .entries(lines))
        var redactor = DiagnosticRedactor(includesPersonalData: personal)
        return DiagnosticReport.compose(input, policy: policy, redactor: &redactor)
    }

    @Test("El stderr del agente y las entradas debug quedan fuera salvo opción explícita")
    func technicalDetailOptIn() {
        let lines = [
            entry("claude stderr: volcado remoto", level: "debug", category: "agent"),
            entry("detalle interno", level: "debug"),
            entry("fallo normal"),
        ]
        let text = compose(lines)
        #expect(text.contains("fallo normal"))
        #expect(!text.contains("volcado remoto") && !text.contains("detalle interno"))
        #expect(text.contains("2 entradas de depuración o del agente omitidas"))
        let full = compose(lines, policy: DiagnosticLogPolicy(includesTechnicalDetail: true))
        #expect(full.contains("volcado remoto") && full.contains("detalle interno"))
    }

    @Test("El tope se aplica DESPUÉS de redactar: nunca queda media clave a la vista")
    func clipAfterRedaction() {
        // El secreto empieza antes del límite de línea y termina después: redactar primero lo elimina entero.
        let secret = "sk-ant-oat01-" + String(repeating: "Z9", count: 40)
        let message = String(repeating: "a", count: 560) + " " + secret + " fin"
        let policy = DiagnosticLogPolicy(includesTechnicalDetail: false, maxBytes: 30_000, maxLineCharacters: 600)
        let text = compose([entry(message)], policy: policy)
        #expect(!text.contains("Z9Z9"))
        #expect(!text.contains("sk-ant-oat01"))
        #expect(text.contains(DiagnosticSecretScrubber.marker))
    }

    @Test("El tope total conserva lo más reciente")
    func totalCap() {
        let lines = (0..<200).map { entry("mensaje \($0) " + String(repeating: "p", count: 80), at: Double($0)) }
        let text = compose(lines, policy: DiagnosticLogPolicy(maxBytes: 2_000))
        #expect(text.contains("mensaje 199"))
        #expect(!text.contains("mensaje 0 "))
        #expect(text.contains("recortado a lo más reciente"))
    }

    @Test("El recordatorio de revisar el texto va al pie")
    func reminder() {
        let text = compose([])
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("no puede garantizar que no se escape alguno."))
    }
}
