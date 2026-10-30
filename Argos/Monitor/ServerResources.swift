//
//  ServerResources.swift
//  Argos
//
//  Modelo y parser (lógica pura) del monitor de recursos del servidor. Los datos
//  salen de `/proc` (Linux) en un único comando SSH (`SSHService.resourcesCommand`)
//  cuyas secciones van separadas por líneas `@@`:
//    loadavg · línea `cpu` de /proc/stat · meminfo · nproc · uptime · df / · ps
//

import Foundation

/// Contadores acumulados de CPU (`/proc/stat`). El % de uso se obtiene comparando dos
/// muestras, porque los contadores son acumulados desde el arranque.
struct CPUTicks: Equatable, Sendable {
    let total: Int
    let idle: Int

    /// Fracción de CPU ocupada (0…1) entre `previous` y esta muestra, o `nil` si no hay
    /// avance (misma muestra o contadores reiniciados).
    func usage(since previous: CPUTicks) -> Double? {
        let totalDelta = total - previous.total
        let idleDelta = idle - previous.idle
        guard totalDelta > 0, idleDelta >= 0 else { return nil }
        return 1 - Double(idleDelta) / Double(totalDelta)
    }
}

/// Capacidad usada / total en KB (memoria, swap o disco).
struct ResourceUsage: Equatable, Sendable {
    let usedKB: Int
    let totalKB: Int

    var fraction: Double {
        totalKB > 0 ? min(max(Double(usedKB) / Double(totalKB), 0), 1) : 0
    }
}

/// Proceso de la lista de los que más CPU consumen.
struct ResourceProcess: Equatable, Sendable, Identifiable {
    let pid: Int
    /// `%CPU` de `ps` (promedio de vida del proceso; puede superar 100 con varios núcleos).
    let cpuPercent: Double
    let memPercent: Double
    let command: String

    var id: Int { pid }
}

/// Una muestra completa de recursos del servidor.
struct ServerResourceSample: Equatable, Sendable {
    let load1: Double
    let load5: Double
    let load15: Double
    let cpu: CPUTicks
    let cores: Int
    let memory: ResourceUsage
    let swap: ResourceUsage
    let disk: ResourceUsage
    let uptimeSeconds: Int
    let topProcesses: [ResourceProcess]
}

enum ServerResourceError: LocalizedError, Equatable {
    /// Sin `/proc` (servidor no Linux) o salida incompleta.
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "No se pudieron leer los recursos: el monitor necesita un servidor Linux (/proc)."
        }
    }
}

enum ServerResourceParser {

    static let separator = "@@"

    /// Parsea la salida de `SSHService.resourcesCommand`. Lanza `.unsupported` si falta
    /// alguna sección obligatoria (la lista de procesos es opcional).
    static func parse(_ output: String) throws -> ServerResourceSample {
        let sections = output
            .components(separatedBy: "\n")
            .split { $0.trimmingCharacters(in: .whitespaces) == separator }
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

        guard sections.count >= 6,
              let load = parseLoad(sections[0]),
              let cpu = parseCPU(sections[1]),
              let memory = parseMemory(sections[2]),
              let cores = sections[3].first.flatMap({ Int($0) }),
              let uptime = sections[4].first.flatMap({ Double($0) }),
              let disk = parseDisk(sections[5])
        else {
            throw ServerResourceError.unsupported
        }

        let processes = sections.count > 6 ? sections[6].compactMap(parseProcess) : []
        return ServerResourceSample(
            load1: load.0, load5: load.1, load15: load.2,
            cpu: cpu,
            cores: cores,
            memory: memory.ram,
            swap: memory.swap,
            disk: disk,
            uptimeSeconds: Int(uptime),
            topProcesses: processes
        )
    }

    private static func fields(_ line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func parseLoad(_ lines: [String]) -> (Double, Double, Double)? {
        guard let f = lines.first.map(fields), f.count >= 3,
              let l1 = Double(f[0]), let l5 = Double(f[1]), let l15 = Double(f[2])
        else { return nil }
        return (l1, l5, l15)
    }

    /// `cpu user nice system idle iowait irq softirq steal …` — idle cuenta iowait.
    private static func parseCPU(_ lines: [String]) -> CPUTicks? {
        guard let f = lines.first.map(fields), f.first == "cpu", f.count >= 9 else { return nil }
        let values = f[1...8].compactMap { Int($0) }
        guard values.count == 8 else { return nil }
        return CPUTicks(total: values.reduce(0, +), idle: values[3] + values[4])
    }

    private static func parseMemory(_ lines: [String]) -> (ram: ResourceUsage, swap: ResourceUsage)? {
        var kb: [String: Int] = [:]
        for line in lines {
            let f = fields(line)
            guard f.count >= 2, let value = Int(f[1]) else { continue }
            kb[String(f[0].dropLast())] = value   // "MemTotal:" -> "MemTotal"
        }
        guard let memTotal = kb["MemTotal"], let memAvailable = kb["MemAvailable"] else { return nil }
        let swapTotal = kb["SwapTotal"] ?? 0
        let swapFree = kb["SwapFree"] ?? 0
        return (
            ResourceUsage(usedKB: memTotal - memAvailable, totalKB: memTotal),
            ResourceUsage(usedKB: swapTotal - swapFree, totalKB: swapTotal)
        )
    }

    /// Línea de `df -Pk /`: `fs 1024-blocks used available capacity mount`.
    private static func parseDisk(_ lines: [String]) -> ResourceUsage? {
        guard let f = lines.last.map(fields), f.count >= 4,
              let total = Int(f[1]), let used = Int(f[2])
        else { return nil }
        return ResourceUsage(usedKB: used, totalKB: total)
    }

    /// `pid pcpu pmem comm` — `comm` puede llevar espacios (p. ej. "tmux: server").
    private static func parseProcess(_ line: String) -> ResourceProcess? {
        let f = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 4, let pid = Int(f[0]), let cpu = Double(f[1]), let mem = Double(f[2])
        else { return nil }
        return ResourceProcess(pid: pid, cpuPercent: cpu, memPercent: mem, command: f[3])
    }
}

/// Formato legible (en español) de tamaños y duraciones.
enum ResourceFormat {

    private static let locale = Locale(identifier: "es_ES")

    static func kilobytes(_ kb: Int) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(kb)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(kb) KB" }
        let number = value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return "\(number) \(units[unit])"
    }

    static func uptime(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) %"
    }
}
