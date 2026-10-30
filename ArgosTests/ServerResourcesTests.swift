//
//  ServerResourcesTests.swift
//  ArgosTests
//
//  Parser del monitor de recursos. El fixture es una salida REAL del comando
//  `SSHService.resourcesCommand` en un Ubuntu 24.04 (servidor dev).
//

import Testing
@testable import Argos

@Suite("Monitor de recursos del servidor")
struct ServerResourcesTests {

    static let fixture = """
    5.73 3.99 3.32 4/999 196002
    @@
    cpu  843449 111347 948277 85909046 80717 0 185867 0 0 0
    @@
    MemTotal:       12247536 kB
    MemAvailable:    4599232 kB
    SwapTotal:             0 kB
    SwapFree:              0 kB
    @@
    6
    @@
    148367.93
    @@
    /dev/sda1        202051056 40518928 161515744      21% /
    @@
     195744  355  6.5 next-build (v16
     196009  300  0.0 ps
      74023 16.7  4.0 claude
    """

    @Test("Parsea carga, núcleos y uptime")
    func parsesLoadCoresUptime() throws {
        let s = try ServerResourceParser.parse(Self.fixture)
        #expect(s.load1 == 5.73)
        #expect(s.load5 == 3.99)
        #expect(s.load15 == 3.32)
        #expect(s.cores == 6)
        #expect(s.uptimeSeconds == 148367)
    }

    @Test("Parsea memoria: usada = total - disponible")
    func parsesMemory() throws {
        let s = try ServerResourceParser.parse(Self.fixture)
        #expect(s.memory.totalKB == 12_247_536)
        #expect(s.memory.usedKB == 12_247_536 - 4_599_232)
        #expect(s.swap.totalKB == 0)
        #expect(s.swap.fraction == 0)
    }

    @Test("Parsea disco raíz")
    func parsesDisk() throws {
        let s = try ServerResourceParser.parse(Self.fixture)
        #expect(s.disk.totalKB == 202_051_056)
        #expect(s.disk.usedKB == 40_518_928)
    }

    @Test("Ticks de CPU: idle incluye iowait y total suma los 8 primeros campos")
    func parsesCPUTicks() throws {
        let s = try ServerResourceParser.parse(Self.fixture)
        #expect(s.cpu.idle == 85_909_046 + 80_717)
        #expect(s.cpu.total == 843_449 + 111_347 + 948_277 + 85_909_046 + 80_717 + 0 + 185_867 + 0)
    }

    @Test("Procesos: el nombre puede contener espacios")
    func parsesProcesses() throws {
        let s = try ServerResourceParser.parse(Self.fixture)
        #expect(s.topProcesses.count == 3)
        #expect(s.topProcesses[0].pid == 195_744)
        #expect(s.topProcesses[0].cpuPercent == 355)
        #expect(s.topProcesses[0].memPercent == 6.5)
        #expect(s.topProcesses[0].command == "next-build (v16")
        #expect(s.topProcesses[2].command == "claude")
    }

    @Test("Uso de CPU entre dos muestras = 1 - Δidle/Δtotal")
    func cpuUsageBetweenSamples() {
        let a = CPUTicks(total: 1000, idle: 800)
        let b = CPUTicks(total: 1200, idle: 850)
        #expect(b.usage(since: a) == 0.75)
    }

    @Test("Sin avance de ticks (o contador reiniciado) no hay uso calculable")
    func cpuUsageWithoutDelta() {
        let a = CPUTicks(total: 1000, idle: 800)
        #expect(a.usage(since: a) == nil)
        #expect(CPUTicks(total: 10, idle: 5).usage(since: a) == nil)
    }

    @Test("Salida sin /proc (p. ej. macOS) o incompleta lanza unsupported")
    func rejectsNonLinux() {
        #expect(throws: ServerResourceError.unsupported) {
            try ServerResourceParser.parse("")
        }
        #expect(throws: ServerResourceError.unsupported) {
            try ServerResourceParser.parse("5.0 4.0 3.0 1/2 3\n@@\n")
        }
    }

    @Test("Formato de bytes legible", arguments: [
        (512, "512 KB"), (2048, "2,0 MB"), (12_247_536, "11,7 GB"), (202_051_056, "192,7 GB"),
    ])
    func formatsKB(kb: Int, expected: String) {
        #expect(ResourceFormat.kilobytes(kb) == expected)
    }

    @Test("Uptime legible", arguments: [
        (59, "59 s"), (3_600, "1 h 0 min"), (148_367, "1 d 17 h"),
    ])
    func formatsUptime(seconds: Int, expected: String) {
        #expect(ResourceFormat.uptime(seconds) == expected)
    }
}
