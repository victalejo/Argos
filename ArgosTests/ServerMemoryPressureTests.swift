//
//  ServerMemoryPressureTests.swift
//  ArgosTests
//
//  Aviso de memoria del servidor: lectura de /proc/meminfo, niveles con histéresis,
//  textos y la sección `memory` del sondeo.
//

import Foundation
import Testing
@testable import Argos

@Suite("Memoria del servidor")
struct ServerMemoryPressureTests {

    /// 12 GB de RAM y 4 GB de swap (el servidor `dev`), con `free` GB libres en total.
    private func reading(freeGB: Double, claude: Int? = 20) -> ServerMemoryReading {
        let gb = 1_048_576.0
        let available = Int(min(freeGB, 12) * gb)
        let swapFree = Int(max(0, freeGB - 12) * gb)
        return ServerMemoryReading(totalKB: Int(12 * gb), availableKB: available, swapTotalKB: Int(4 * gb), swapFreeKB: swapFree, claudeProcesses: claude)
    }

    @Test("Lee las líneas mem y claude")
    func parsesLines() throws {
        let reading = try #require(ServerMemoryReading(lines: ["mem 12247536 10941320 4194300 3663664", "claude 7"]))
        #expect(reading.totalKB == 12_247_536)
        #expect(reading.availableKB == 10_941_320)
        #expect(reading.swapTotalKB == 4_194_300)
        #expect(reading.swapFreeKB == 3_663_664)
        #expect(reading.claudeProcesses == 7)
    }

    @Test("Sin línea claude: la lectura vale igual")
    func parsesWithoutClaude() {
        #expect(ServerMemoryReading(lines: ["mem 100 50 0 0"])?.claudeProcesses == nil)
    }

    @Test("Sin /proc/meminfo (macOS) o datos raros: sin lectura", arguments: [
        ["claude 3"],
        ["mem 100 50 0"],
        ["mem 0 0 0 0", "claude 1"],
        ["mem a b c d"],
    ])
    func rejectsInvalid(lines: [String]) {
        #expect(ServerMemoryReading(lines: lines) == nil)
    }

    @Test("Fracción libre y porcentaje usado cuentan RAM y swap")
    func fractions() {
        let reading = ServerMemoryReading(totalKB: 12, availableKB: 3, swapTotalKB: 4, swapFreeKB: 1, claudeProcesses: nil)
        #expect(reading.freeFraction == 0.25)
        #expect(reading.usedPercent == 75)
        let empty = ServerMemoryReading(totalKB: 1, availableKB: 0, swapTotalKB: 0, swapFreeKB: 0, claudeProcesses: nil)
        #expect(empty.usedPercent == 100)
    }

    @Test("Niveles por umbral", arguments: [
        (12.0, MemoryPressureLevel.normal),   // 75 % libre
        (4.0, .normal),                       // 25 %
        (3.0, .high),                         // 18,75 %
        (2.0, .high),                         // 12,5 %
        (1.0, .critical),                     // 6,25 %
    ])
    func levels(freeGB: Double, expected: MemoryPressureLevel) {
        #expect(ServerMemoryPressure.evaluate(reading(freeGB: freeGB), previous: nil).level == expected)
    }

    @Test("Histéresis: el aviso no se quita hasta pasar del 25 % libre")
    func hysteresis() {
        let at22 = reading(freeGB: 16 * 0.22)
        #expect(ServerMemoryPressure.evaluate(at22, previous: nil).level == .normal)
        #expect(ServerMemoryPressure.evaluate(at22, previous: .high).level == .high)
        #expect(ServerMemoryPressure.evaluate(at22, previous: .critical).level == .high)
        let at26 = reading(freeGB: 16 * 0.26)
        #expect(ServerMemoryPressure.evaluate(at26, previous: .high).level == .normal)
    }

    @Test("Solo el nivel crítico pide confirmar antes de abrir otra sesión")
    func confirmation() {
        #expect(ServerMemoryPressure.evaluate(reading(freeGB: 1), previous: nil).needsConfirmationToStart)
        #expect(!ServerMemoryPressure.evaluate(reading(freeGB: 3), previous: nil).needsConfirmationToStart)
    }

    @Test("El mensaje da el porcentaje y los procesos de Claude")
    func message() {
        let pressure = ServerMemoryPressure.evaluate(reading(freeGB: 1, claude: 20), previous: nil)
        #expect(pressure.message.contains("94"))
        #expect(pressure.message.contains("20"))
        let noClaude = ServerMemoryPressure.evaluate(reading(freeGB: 1, claude: 0), previous: nil)
        #expect(!noClaude.message.contains("Claude"))
    }

    @Test("La sección memory del sondeo se interpreta y viaja en la salida")
    func pollSection() {
        let output = """
        @@argos-poll:memory
        mem 12247536 1000000 4194300 0
        claude 24
        @@argos-poll:end
        """
        let parsed = WorkspacePollCommand.parse(output, requested: [.memory])
        #expect(parsed.memory?.claudeProcesses == 24)
        #expect(WorkspacePollCommand.parse(output, requested: [.claude]).memory == nil)
        // Cortada por el plazo (sin marcador final): sin dato.
        let cut = "@@argos-poll:memory\nmem 12247536 1000000 4194300 0\n"
        #expect(WorkspacePollCommand.parse(cut, requested: [.memory]).memory == nil)
    }

    @Test("El script del sondeo incluye la memoria")
    func pollScript() {
        let script = WorkspacePollCommand.script(for: [.memory])
        #expect(script.contains("@@argos-poll:memory"))
        #expect(script.contains("/proc/meminfo"))
        #expect(script.contains("pgrep -x -u"))
    }

    @MainActor
    @Test("El sondeo deja la presión en el view model y una vuelta sin dato no la borra")
    func viewModelAbsorbs() async {
        let mock = MockSSHService()
        mock.memoryReading = reading(freeGB: 1)
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        _ = await vm.pollWorkspace([.memory])
        #expect(vm.memoryPressure?.level == .critical)

        mock.memoryReading = nil
        _ = await vm.pollWorkspace([.memory])
        #expect(vm.memoryPressure?.level == .critical)

        mock.memoryReading = reading(freeGB: 12)
        _ = await vm.pollWorkspace([.memory])
        #expect(vm.memoryPressure?.level == .normal)
    }
}
