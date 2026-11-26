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

    @Test func leeLasVentanasEnOrdenYPasaLasHorasAlRelojLocal() throws {
        // El reloj del servidor va 100 s por detrás del local.
        let local = Date(timeIntervalSince1970: 1_799_990_100)
        let reading = try #require(ClaudeLimitsReading(
            lines: ["now 1799990000", "1799989000", Self.statusLine], localNow: local
        ))
        #expect(reading.windows.map(\.kind) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(reading.windows[0].usedPercent == 42.5)
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_100))
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

    @Test func avisaSoloAlSubirDeNivelOConUnaVentanaNueva() throws {
        func status(_ percent: Double, reset: TimeInterval = 5_000) -> ClaudeLimitsStatus? {
            ClaudeLimitsStatus.evaluate(ClaudeLimitsReading(windows: [
                ClaudeLimitWindow(kind: "five_hour", usedPercent: percent, resetsAt: Date(timeIntervalSince1970: reset)),
            ], capturedAt: Date(timeIntervalSince1970: 0)), now: Date(timeIntervalSince1970: 0))
        }
        #expect(ClaudeLimitAlert.transition(from: status(50), to: status(80)) == nil)
        #expect(ClaudeLimitAlert.transition(from: status(80), to: status(86)) != nil)
        // El reinicio «baila» unos segundos al pasar al reloj local: sigue siendo el mismo.
        #expect(ClaudeLimitAlert.transition(from: status(86), to: status(88, reset: 5_030)) == nil)
        #expect(ClaudeLimitAlert.transition(from: status(88), to: status(96)) != nil)
        #expect(ClaudeLimitAlert.transition(from: status(96), to: status(90)) == nil)
        // Ventana nueva (otro reinicio) que ya llega alta: se avisa de nuevo.
        #expect(ClaudeLimitAlert.transition(from: status(96), to: status(90, reset: 30_000)) != nil)
        #expect(ClaudeLimitAlert.transition(from: nil, to: status(90)) != nil)
        #expect(ClaudeLimitAlert.transition(from: status(90), to: nil) == nil)
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

    @Test func conservaLaStatuslineDelUsuarioYSusOpciones() {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "~/bin/mi-barra.sh", "padding": 2]]
        let result = ClaudeLimitsInstaller.installing(into: settings)
        let statusLine = result.settings["statusLine"] as? [String: Any]
        #expect(result.previousCommand == "~/bin/mi-barra.sh")
        #expect(statusLine?["padding"] as? Int == 2)
        // Quitarla devuelve la del usuario.
        let restored = ClaudeLimitsInstaller.removing(from: result.settings, previousCommand: "~/bin/mi-barra.sh\n")
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
        #expect(ClaudeLimitsInstaller.removing(from: installed, previousCommand: nil)["statusLine"] == nil)
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
        try #"printf 'mi barra: '; cat"#.write(to: box.file(ClaudeLimitsInstaller.previousRelativePath), atomically: true, encoding: .utf8)

        let result = try box.run(shell, input: Self.withLimits)
        #expect(result.status == 0)
        #expect(result.output == "mi barra: " + Self.withLimits)

        let saved = try String(contentsOf: box.file(ClaudeLimitsInstaller.limitsRelativePath), encoding: .utf8)
        let lines = saved.split(separator: "\n").map(String.init)
        #expect(Int(lines[0]) != nil)
        #expect(lines[1] == Self.withLimits)
        let attributes = try FileManager.default.attributesOfItem(atPath: box.file(ClaudeLimitsInstaller.limitsRelativePath).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // Y la sección del sondeo lo lee.
        let poll = try LocalShell.run(ClaudeLimitsInstaller.pollCommand, home: box.home)
        let reading = ClaudeLimitsReading(lines: poll.stdout.split(separator: "\n").map(String.init))
        #expect(reading?.windows.first?.usedPercent == 8)
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
        #expect(vm.absorbLimits(reading(40)) == nil)
        #expect(vm.claudeLimits?.worstPercent == 40)
        #expect(vm.absorbLimits(reading(88))?.status.level == .high)
        #expect(vm.absorbLimits(reading(89)) == nil)
        #expect(vm.absorbLimits(nil) == nil)
        #expect(vm.claudeLimits == nil)
    }
}
