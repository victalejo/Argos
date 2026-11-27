//
//  ServerMetricsHistory.swift
//  ArgosCore
//
//  Historial de recursos tal como lo lee la app (lógica pura): parseo de la salida de
//  `ServerMetricsScript.historyCommand` y reducción a pocos puntos para las gráficas. La
//  salida viene del servidor: se valida cada cifra y se descarta lo que no cuadra.
//

import Foundation

/// Un punto del historial (una muestra de minuto o un agregado de 10 min).
struct ServerMetricsPoint: Equatable, Sendable, Identifiable {
    let date: Date
    let memTotalKB: Int
    let memAvailableKB: Int
    let swapTotalKB: Int
    let swapFreeKB: Int
    /// Uso de CPU (0…1); `nil` si no había muestra anterior.
    let cpu: Double?
    /// Carga media de 1 min (en el agregado, la máxima del tramo).
    let load: Double?
    let claudeProcesses: Int?
    /// Memoria de los procesos de Claude con sus hijos (MCP, node…).
    let claudeRSSKB: Int?

    var id: Date { date }

    var memoryUsedFraction: Double {
        memTotalKB > 0 ? min(1, max(0, Double(memTotalKB - memAvailableKB) / Double(memTotalKB))) : 0
    }

    /// `nil` sin swap.
    var swapUsedFraction: Double? {
        swapTotalKB > 0 ? min(1, max(0, Double(swapTotalKB - swapFreeKB) / Double(swapTotalKB))) : nil
    }
}

/// Muerte por falta de memoria registrada por el kernel (o systemd-oomd).
struct ServerOOMMark: Equatable, Sendable, Identifiable {
    let date: Date
    let process: String

    var id: String { "\(date.timeIntervalSince1970)-\(process)" }
}

/// Proceso con más memoria en la última muestra.
struct ServerMemoryHog: Equatable, Sendable, Identifiable {
    let pid: Int
    let rssKB: Int
    let name: String

    var id: Int { pid }
}

struct ServerMetricsHistory: Equatable, Sendable {
    /// El muestreo está instalado en el servidor.
    var isInstalled = false
    /// El servidor no tiene `/proc` (no es Linux): no hay datos que guardar.
    var lacksProc = false
    var timer: ClaudeTaskTimer.Kind = .none
    var serverNow: Date?
    var points: [ServerMetricsPoint] = []
    var oomMarks: [ServerOOMMark] = []
    var topProcesses: [ServerMemoryHog] = []

    /// Muestreo puesto pero sin temporizador que lo dispare.
    var isStalled: Bool { isInstalled && timer == .none }

    private static let maxKB = ServerResourceParser.maxCounter
    /// Fechas razonables (2001…2100): descarta basura sin abortar al convertir.
    private static let validTimestamps = 1_000_000_000...4_102_444_800

    static func parse(_ output: String) -> ServerMetricsHistory {
        var history = ServerMetricsHistory()
        var points: [Date: ServerMetricsPoint] = [:]
        var marks: [ServerOOMMark] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let fields = raw.split(separator: " ").map(String.init)
            switch fields.first {
            case "@@installed": history.isInstalled = true
            case "@@noproc": history.lacksProc = true
            case "@@timer": history.timer = ClaudeTaskTimer.Kind(rawValue: fields.count > 1 ? fields[1] : "") ?? .none
            case "@@now": history.serverNow = fields.count > 1 ? date(fields[1]) : nil
            case "@@top": history.topProcesses = fields.count > 1 ? parseTop(fields[1]) : []
            case "m", "a":
                if let point = parsePoint(fields) { points[point.date] = point }
            case "o":
                if fields.count >= 3, let when = date(fields[1]) {
                    marks.append(ServerOOMMark(date: when, process: sanitizedName(fields[2])))
                }
            default:
                continue
            }
        }
        history.points = points.values.sorted { $0.date < $1.date }
        history.oomMarks = marks.sorted { $0.date < $1.date }
        return history
    }

    private static func date(_ text: String) -> Date? {
        guard let value = Int(text), validTimestamps.contains(value) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    /// `<tipo> <ts> <memTotal> <memDisp> <swapTotal> <swapLibre> <cpu‰> <carga×100> <n> <rss>`.
    private static func parsePoint(_ fields: [String]) -> ServerMetricsPoint? {
        guard fields.count >= 10, let when = date(fields[1]) else { return nil }
        let numbers = fields[2...9].map { Int($0) }
        guard let total = numbers[0], let available = numbers[1], let swapTotal = numbers[2], let swapFree = numbers[3],
              (1...maxKB).contains(total), (0...total).contains(available),
              (0...maxKB).contains(swapTotal), (0...maxKB).contains(swapFree)
        else { return nil }
        let cpu = numbers[4].flatMap { (0...1000).contains($0) ? Double($0) / 1000 : nil }
        let load = numbers[5].flatMap { (0...100_000_000).contains($0) ? Double($0) / 100 : nil }
        let claude = numbers[6].flatMap { (0...100_000).contains($0) ? $0 : nil }
        let claudeRSS = numbers[7].flatMap { (0...maxKB).contains($0) ? $0 : nil }
        return ServerMetricsPoint(
            date: when, memTotalKB: total, memAvailableKB: available,
            swapTotalKB: swapTotal, swapFreeKB: min(swapFree, swapTotal),
            cpu: cpu, load: load, claudeProcesses: claude, claudeRSSKB: claudeRSS
        )
    }

    /// `pid:rss:nombre,…` (como mucho 5).
    static func parseTop(_ text: String) -> [ServerMemoryHog] {
        text.split(separator: ",").prefix(5).compactMap { item in
            let parts = item.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let pid = Int(parts[0]), pid > 0, let rss = Int(parts[1]),
                  (0...maxKB).contains(rss)
            else { return nil }
            return ServerMemoryHog(pid: pid, rssKB: rss, name: sanitizedName(parts[2]))
        }
    }

    /// El servidor ya sanea los nombres; se repite aquí por si el archivo se manipuló.
    static func sanitizedName(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let clean = String(text.filter { allowed.contains($0) }.prefix(24))
        return clean.isEmpty ? "?" : clean
    }

    // MARK: - Para las gráficas

    /// Reduce a `maxPoints` como mucho agrupando puntos seguidos: memoria y swap con el
    /// PEOR valor del grupo (un pico de memoria no debe desaparecer al reducir), CPU media,
    /// carga y memoria de Claude máximas.
    static func downsample(_ points: [ServerMetricsPoint], maxPoints: Int) -> [ServerMetricsPoint] {
        guard maxPoints > 0, points.count > maxPoints else { return points }
        let size = Int((Double(points.count) / Double(maxPoints)).rounded(.up))
        return stride(from: 0, to: points.count, by: size).compactMap { start in
            merge(points[start..<min(start + size, points.count)])
        }
    }

    private static func merge(_ group: ArraySlice<ServerMetricsPoint>) -> ServerMetricsPoint? {
        guard let first = group.first, let last = group.last else { return nil }
        if group.count == 1 { return first }
        let cpus = group.compactMap(\.cpu)
        let worstMemory = group.min { $0.memAvailableKB < $1.memAvailableKB } ?? last
        let worstSwap = group.min { $0.swapFreeKB < $1.swapFreeKB } ?? last
        return ServerMetricsPoint(
            date: first.date,
            memTotalKB: worstMemory.memTotalKB, memAvailableKB: worstMemory.memAvailableKB,
            swapTotalKB: worstSwap.swapTotalKB, swapFreeKB: worstSwap.swapFreeKB,
            cpu: cpus.isEmpty ? nil : cpus.reduce(0, +) / Double(cpus.count),
            load: group.compactMap(\.load).max(),
            claudeProcesses: group.compactMap(\.claudeProcesses).max(),
            claudeRSSKB: group.compactMap(\.claudeRSSKB).max()
        )
    }
}
