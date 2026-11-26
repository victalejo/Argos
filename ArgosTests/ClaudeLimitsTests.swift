//
//  ClaudeLimitsTests.swift
//  ArgosTests
//
//  Límites de uso de Claude: lectura de la statusline, niveles y avisos, fusión de
//  settings.json y el script real de la statusline ejecutado con sh y dash.
//

import Testing
import Foundation
@testable import Argos

@Suite("Límites de Claude (lectura y niveles)")
struct ClaudeLimitsReadingTests {

    private static let statusLine = #"{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1800000000},"seven_day":{"used_percentage":8,"resets_at":1800300000},"seven_day_opus":{"used_percentage":91}}}"#

    @Test func leeLasVentanasEnOrdenYPasaLaHoraDeGuardadoAlRelojLocal() throws {
        // El reloj del servidor va 100 s por detrás del local.
        let local = Date(timeIntervalSince1970: 1_799_990_100)
        let reading = try #require(ClaudeLimitsReading(
            lines: ["now 1799990000", "1799989000", Self.statusLine], localNow: local
        ))
        #expect(reading.windows.map(\.kind) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(reading.windows[0].usedPercent == 42.5)
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "hora de Anthropic: sin corregir")
        #expect(reading.windows[2].resetsAt == nil)
        #expect(reading.capturedAt == Date(timeIntervalSince1970: 1_799_989_100))
    }

    @Test func sinArchivoOSinLimitesNoHayLectura() {
        #expect(ClaudeLimitsReading(lines: ["now 1799990000"]) == nil)
        #expect(ClaudeLimitsReading(lines: ["now 1799990000", "1799989000", #"{"model":{}}"#]) == nil)
        #expect(ClaudeLimitsReading(lines: ["now 1799990000", "1799989000", "no es json"]) == nil)
        #expect(ClaudeLimitsReading(lines: []) == nil)
    }

    @Test func aceptaResetsEnIsoYEnMilisegundos() throws {
        let iso = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":"2027-01-15T10:00:00Z"}}}"#
        let millis = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1800000000000}}}"#
        let fromISO = try #require(ClaudeLimitsReading.windows(fromStatusLineJSON: iso))
        let fromMillis = try #require(ClaudeLimitsReading.windows(fromStatusLineJSON: millis))
        #expect(fromISO.first?.resetsAt == ISO8601DateFormatter().date(from: "2027-01-15T10:00:00Z"))
        #expect(fromMillis.first?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Nivel según la ventana más llena", arguments: [
        (50.0, ClaudeLimitsLevel.normal), (84.4, .normal), (85.0, .high), (94.0, .high), (95.0, .critical), (100.0, .critical),
    ])
    func level(percent: Double, expected: ClaudeLimitsLevel) throws {
        let reading = ClaudeLimitsReading(windows: [
            ClaudeLimitWindow(kind: "five_hour", usedPercent: 10, resetsAt: nil),
            ClaudeLimitWindow(kind: "seven_day", usedPercent: percent, resetsAt: nil),
        ], capturedAt: Date())
        let status = try #require(ClaudeLimitsStatus.evaluate(reading))
        #expect(status.level == expected)
        #expect(status.worst.kind == (percent > 10 ? "seven_day" : "five_hour"))
    }

    @Test func unaVentanaYaReiniciadaCuentaComoCero() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let reading = ClaudeLimitsReading(windows: [
            ClaudeLimitWindow(kind: "five_hour", usedPercent: 99, resetsAt: Date(timeIntervalSince1970: 1_000)),
            ClaudeLimitWindow(kind: "seven_day", usedPercent: 30, resetsAt: Date(timeIntervalSince1970: 9_000)),
        ], capturedAt: now)
        let status = try #require(ClaudeLimitsStatus.evaluate(reading, now: now))
        #expect(status.level == .normal)
        #expect(status.worst.kind == "seven_day")
        #expect(status.worstPercent == 30)
    }

    private static func reading(_ windows: [(String, Double, TimeInterval)]) -> ClaudeLimitsReading {
        ClaudeLimitsReading(windows: windows.map {
            ClaudeLimitWindow(kind: $0.0, usedPercent: $0.1, resetsAt: Date(timeIntervalSince1970: $0.2))
        }, capturedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func avisaSoloAlSubirDeNivelOConUnaVentanaNueva() {
        let now = Date(timeIntervalSince1970: 0)
        func alerts(_ old: [(String, Double, TimeInterval)]?, _ new: [(String, Double, TimeInterval)]?) -> [ClaudeLimitAlert] {
            ClaudeLimitAlert.transitions(from: old.map(Self.reading), to: new.map(Self.reading), now: now)
        }
        #expect(alerts([("five_hour", 50, 5_000)], [("five_hour", 80, 5_000)]).isEmpty)
        #expect(alerts([("five_hour", 80, 5_000)], [("five_hour", 86, 5_000)]).map(\.level) == [.high])
        #expect(alerts([("five_hour", 86, 5_000)], [("five_hour", 88, 5_030)]).isEmpty, "mismo reinicio con margen")
        #expect(alerts([("five_hour", 88, 5_000)], [("five_hour", 96, 5_000)]).map(\.level) == [.critical])
        #expect(alerts([("five_hour", 96, 5_000)], [("five_hour", 90, 5_000)]).isEmpty)
        #expect(alerts([("five_hour", 96, 5_000)], [("five_hour", 90, 30_000)]).count == 1, "ventana nueva ya alta")
        #expect(alerts(nil, [("five_hour", 90, 5_000)]).count == 1)
        #expect(alerts([("five_hour", 90, 5_000)], nil).isEmpty)
    }

    @Test func queCambieLaVentanaMasLlenaNoRepiteElAvisoDeOtra() {
        let now = Date(timeIntervalSince1970: 0)
        // La semana ya avisó al 86 %; sube la de 5 h y luego la de 5 h se reinicia.
        let before = Self.reading([("five_hour", 20, 5_000), ("seven_day", 86, 90_000)])
        let fiveUp = Self.reading([("five_hour", 90, 5_000), ("seven_day", 86, 90_000)])
        let fiveReset = Self.reading([("five_hour", 3, 23_000), ("seven_day", 87, 90_000)])
        #expect(ClaudeLimitAlert.transitions(from: before, to: fiveUp, now: now).map(\.window.kind) == ["five_hour"])
        #expect(ClaudeLimitAlert.transitions(from: fiveUp, to: fiveReset, now: now).isEmpty)
    }

    @Test func dentroDeUnaVentanaSeQuedaElUsoMasAlto() {
        // Otra sesión de Claude, parada, escribió un porcentaje viejo de la misma ventana.
        let fresh = Self.reading([("five_hour", 88, 5_000), ("seven_day", 10, 90_000)])
        let stale = Self.reading([("five_hour", 60, 5_100), ("seven_day", 12, 90_000)])
        let merged = stale.merging(previous: fresh)
        #expect(merged.windows.map(\.usedPercent) == [88, 12])
        // Con otra ventana (otro reinicio) manda la nueva aunque sea menor.
        let next = Self.reading([("five_hour", 5, 23_000)])
        #expect(next.merging(previous: fresh).windows.map(\.usedPercent) == [5])
    }

    @Test func elRelojDelServidorNoMueveElReinicioQueDaAnthropic() throws {
        let reading = try #require(ClaudeLimitsReading(
            lines: ["now 1000", "990", #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":5000}}}"#],
            localNow: Date(timeIntervalSince1970: 2_000)
        ))
        #expect(reading.windows.first?.resetsAt == Date(timeIntervalSince1970: 5_000))
        #expect(reading.capturedAt == Date(timeIntervalSince1970: 1_990))
    }

    @Test func elRegistroDeAvisosDaCadaUnoUnaSolaVez() throws {
        let defaults = try #require(UserDefaults(suiteName: "argos-tests-\(UUID().uuidString)"))
        #expect(ClaudeLimitAlertLedger.claim("a", defaults: defaults))
        #expect(!ClaudeLimitAlertLedger.claim("a", defaults: defaults))
        for index in 0..<ClaudeLimitAlertLedger.capacity { ClaudeLimitAlertLedger.claim("k\(index)", defaults: defaults) }
        #expect(ClaudeLimitAlertLedger.claim("a", defaults: defaults), "las más viejas se olvidan")
    }

    @Test func elTextoDeReinicioDiceHoyMananaOElDia() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15))!
        let today = calendar.date(byAdding: .hour, value: 3, to: now)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let later = calendar.date(byAdding: .day, value: 4, to: now)!
        #expect(ClaudeLimitsStatus.resetText(today, now: now, calendar: calendar).hasPrefix("a las"))
        #expect(ClaudeLimitsStatus.resetText(tomorrow, now: now, calendar: calendar).hasPrefix("mañana a las"))
        #expect(ClaudeLimitsStatus.resetText(later, now: now, calendar: calendar).hasPrefix("el "))
    }
}

@Suite("Límites de Claude (statusline en settings.json)")
struct ClaudeLimitsInstallerTests {

    @Test func sinStatuslinePreviaLaCreaYGuardaAnteriorVacia() {
        let result = ClaudeLimitsInstaller.installing(into: ["model": "opus"])
        let statusLine = result.settings["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == ClaudeLimitsInstaller.command)
        #expect(statusLine?["type"] as? String == "command")
        #expect(result.settings["model"] as? String == "opus")
        #expect(result.previousCommand == "")
        #expect(ClaudeLimitsInstaller.isInstalled(in: result.settings))
        #expect(ClaudeLimitsInstaller.isCurrent(in: result.settings))
    }

    @Test func conservaLaStatuslineDelUsuarioYSusOpciones() throws {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "~/bin/mi-barra.sh", "padding": 2]]
        let result = ClaudeLimitsInstaller.installing(into: settings)
        let statusLine = result.settings["statusLine"] as? [String: Any]
        #expect(result.previousCommand == "~/bin/mi-barra.sh")
        #expect(statusLine?["padding"] as? Int == 2)
        // Quitarla devuelve la del usuario (leída del archivo con cabecera).
        let file = ClaudeLimitsInstaller.previousFileContents(result.previousCommand ?? "")
        let previous = try #require(ClaudeLimitsInstaller.previousCommand(fromFile: file))
        let restored = ClaudeLimitsInstaller.removing(from: result.settings, previousCommand: previous)
        let back = restored["statusLine"] as? [String: Any]
        #expect(back?["command"] as? String == "~/bin/mi-barra.sh")
        #expect(back?["padding"] as? Int == 2)
    }

    @Test func instalarDosVecesNoPisaLaAnteriorGuardada() {
        let first = ClaudeLimitsInstaller.installing(into: ["statusLine": ["type": "command", "command": "mi-barra"]])
        let second = ClaudeLimitsInstaller.installing(into: first.settings)
        #expect(second.previousCommand == nil, "la anterior ya guardada es la del usuario, no la nuestra")
    }

    @Test func quitarSinAnteriorBorraStatusline() {
        let installed = ClaudeLimitsInstaller.installing(into: [:]).settings
        let removed = ClaudeLimitsInstaller.removing(from: installed, previousCommand: "")
        #expect(removed["statusLine"] == nil)
    }

    @Test func unArchivoAnteriorSinCabeceraNoValeComoAnterior() {
        #expect(ClaudeLimitsInstaller.previousCommand(fromFile: "") == nil, "archivo ausente")
        #expect(ClaudeLimitsInstaller.previousCommand(fromFile: "mi-barra.sh\n") == nil)
        #expect(ClaudeLimitsInstaller.previousCommand(fromFile: ClaudeLimitsInstaller.previousFileContents("")) == "")
        #expect(ClaudeLimitsInstaller.previousCommand(fromFile: ClaudeLimitsInstaller.previousFileContents("a | b")) == "a | b")
    }

    @Test func quitarNoTocaUnaStatuslineAjena() {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "otra"]]
        let result = ClaudeLimitsInstaller.removing(from: settings, previousCommand: "vieja")
        #expect((result["statusLine"] as? [String: Any])?["command"] as? String == "otra")
    }
}

@Suite("Límites de Claude (script de la statusline)")
struct ClaudeLimitsScriptTests {

    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Sandbox {
        let home: URL
        init() throws {
            home = try LocalShell.makeTemporaryDirectory()
            let dir = home.appendingPathComponent(".config/argos", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ClaudeLimitsInstaller.script.write(
                to: home.appendingPathComponent(ClaudeLimitsInstaller.scriptRelativePath), atomically: true, encoding: .utf8
            )
        }

        func file(_ relative: String) -> URL { home.appendingPathComponent(relative) }

        func run(_ shell: String, input: String) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [file(ClaudeLimitsInstaller.scriptRelativePath).path]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        func remove() { LocalShell.remove(home) }
    }

    private static let withLimits = #"{"cwd":"/x","rate_limits":{"seven_day":{"used_percentage":8,"resets_at":1796014800}}}"#

    @Test("Guarda los límites y ejecuta la statusline anterior", arguments: shells)
    func savesAndDelegates(shell: String) throws {
        let box = try Sandbox()
        defer { box.remove() }
        try ClaudeLimitsInstaller.previousFileContents(#"printf 'mi barra: '; cat"#)
            .write(to: box.file(ClaudeLimitsInstaller.previousRelativePath), atomically: true, encoding: .utf8)

        let result = try box.run(shell, input: Self.withLimits)
        #expect(result.status == 0)
        #expect(result.output == "mi barra: " + Self.withLimits)

        let saved = try String(contentsOf: box.file(ClaudeLimitsInstaller.limitsRelativePath), encoding: .utf8)
        let lines = saved.split(separator: "\n").map(String.init)
        #expect(Int(lines[0]) != nil)
        #expect(lines[1] == Self.withLimits)
        let attributes = try FileManager.default.attributesOfItem(atPath: box.file(ClaudeLimitsInstaller.limitsRelativePath).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // La sección del sondeo solo lo lee con la statusline de Argos puesta.
        let pollLines = { try LocalShell.run(ClaudeLimitsInstaller.pollCommand, home: box.home).stdout.split(separator: "\n").map(String.init) }
        #expect(ClaudeLimitsReading(lines: try pollLines()) == nil)
        try FileManager.default.createDirectory(at: box.file(".claude"), withIntermediateDirectories: true)
        let settings = try ClaudeHookInstaller.serialize(ClaudeLimitsInstaller.installing(into: [:]).settings)
        try settings.write(to: box.file(".claude/settings.json"), atomically: true, encoding: .utf8)
        #expect(ClaudeLimitsReading(lines: try pollLines())?.windows.first?.usedPercent == 8)
    }

    @Test("Sin porcentajes no pisa lo guardado y sin anterior no imprime nada", arguments: shells)
    func ignoresInputWithoutLimits(shell: String) throws {
        let box = try Sandbox()
        defer { box.remove() }
        _ = try box.run(shell, input: Self.withLimits)
        let before = try String(contentsOf: box.file(ClaudeLimitsInstaller.limitsRelativePath), encoding: .utf8)

        let result = try box.run(shell, input: #"{"cwd":"/x","model":{"id":"y"}}"#)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(try String(contentsOf: box.file(ClaudeLimitsInstaller.limitsRelativePath), encoding: .utf8) == before)
    }
}

@MainActor
@Suite("Límites de Claude (activación y view model)")
struct ClaudeLimitsModelTests {

    @Test func activarYQuitarCambianElEstado() async {
        let mock = MockSSHService()
        let model = ClaudeLimitsSetupModel(service: mock)
        await model.refresh()
        #expect(model.state == .inactive)
        await model.activate()
        #expect(model.state == .active)
        #expect(mock.claudeLimitsActive)
        #expect(model.notice != nil)
        await model.deactivate()
        #expect(model.state == .inactive)
        #expect(!mock.claudeLimitsActive)
    }

    @Test func elViewModelAvisaAlCruzarElUmbralYOlvidaAlQuitarse() {
        let vm = SessionsViewModel(service: MockSSHService())
        func reading(_ percent: Double) -> ClaudeLimitsReading {
            ClaudeLimitsReading(windows: [
                ClaudeLimitWindow(kind: "five_hour", usedPercent: percent, resetsAt: Date().addingTimeInterval(3600)),
            ], capturedAt: Date())
        }
        #expect(vm.absorbLimits(reading(40)).isEmpty)
        #expect(vm.claudeLimits?.worstPercent == 40)
        #expect(vm.absorbLimits(reading(88)).first?.level == .high)
        #expect(vm.absorbLimits(reading(89)).isEmpty)
        #expect(vm.absorbLimits(reading(60)).isEmpty, "un dato viejo de otra sesión no baja el uso")
        #expect(vm.claudeLimits?.worstPercent == 89)
        #expect(vm.absorbLimits(nil).isEmpty)
        #expect(vm.claudeLimits == nil)
    }
}
