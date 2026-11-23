//
//  ServerMemoryPressure.swift
//  ArgosCore
//
//  ¿Se está quedando sin memoria el servidor? (lógica pura). Cada sesión con Claude ocupa
//  0,5–1 GB con sus servidores MCP y el servidor del usuario ya se quedó dos veces sin
//  memoria (el kernel mató la sesión de usuario y con ella todo tmux). Con esto Argos avisa
//  ANTES, mientras aún se puede cerrar algo. Lo lee la sección `memory` del sondeo
//  (`WorkspacePollCommand`); Android lo porta en `ServerMemoryPressure.kt`.
//

import Foundation

/// Lectura de memoria del servidor (KB, de /proc/meminfo; solo Linux).
struct ServerMemoryReading: Equatable, Sendable {
    let totalKB: Int
    let availableKB: Int
    let swapTotalKB: Int
    let swapFreeKB: Int
    /// Procesos `claude` del usuario (`nil` si no se pudo contar).
    let claudeProcesses: Int?

    /// Fracción libre de RAM + swap juntas (0…1): con swap, el sistema aguanta hasta
    /// llenar ambas antes de empezar a matar procesos.
    var freeFraction: Double {
        let total = totalKB + swapTotalKB
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(availableKB + swapFreeKB) / Double(total)))
    }

    /// Porcentaje usado (RAM + swap), redondeado.
    var usedPercent: Int { Int(((1 - freeFraction) * 100).rounded()) }

    /// Interpreta la sección `memory` del sondeo: `mem <total> <disponible> <swapTotal>
    /// <swapLibre>` y `claude <n>`. `nil` si no hay línea `mem` válida (servidor no Linux).
    init?(lines: [String]) {
        var memory: [Int]?
        var claude: Int?
        for line in lines {
            let fields = line.split(separator: " ").map(String.init)
            switch fields.first {
            case "mem":
                let numbers = fields.dropFirst().compactMap(Int.init)
                if numbers.count == 4, numbers[0] > 0 { memory = numbers }
            case "claude":
                claude = fields.count > 1 ? Int(fields[1]) : nil
            default:
                continue
            }
        }
        guard let memory else { return nil }
        self.init(totalKB: memory[0], availableKB: memory[1], swapTotalKB: memory[2], swapFreeKB: memory[3], claudeProcesses: claude)
    }

    init(totalKB: Int, availableKB: Int, swapTotalKB: Int, swapFreeKB: Int, claudeProcesses: Int?) {
        self.totalKB = totalKB
        self.availableKB = availableKB
        self.swapTotalKB = swapTotalKB
        self.swapFreeKB = swapFreeKB
        self.claudeProcesses = claudeProcesses
    }
}

enum MemoryPressureLevel: Int, Comparable, Sendable {
    case normal
    case high
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Estado de memoria de un servidor tal como lo enseña la app.
struct ServerMemoryPressure: Equatable, Sendable {
    let level: MemoryPressureLevel
    let reading: ServerMemoryReading

    /// Por debajo de esta fracción libre (RAM + swap) se avisa.
    static let highBelow = 0.20
    /// Por debajo de esta, el aviso es urgente y abrir otra sesión pide confirmación.
    static let criticalBelow = 0.10
    /// Un aviso ya mostrado no se quita hasta superar esto (no parpadea en el umbral).
    static let clearAbove = 0.25

    /// Nivel para `reading` sabiendo el anterior (histéresis al bajar).
    static func evaluate(_ reading: ServerMemoryReading, previous: MemoryPressureLevel?) -> ServerMemoryPressure {
        let free = reading.freeFraction
        let level: MemoryPressureLevel
        if free < criticalBelow {
            level = .critical
        } else if free < highBelow {
            level = .high
        } else if let previous, previous > .normal, free < clearAbove {
            level = .high
        } else {
            level = .normal
        }
        return ServerMemoryPressure(level: level, reading: reading)
    }

    var title: String {
        switch level {
        case .normal: return String(localized: "Memoria del servidor correcta")
        case .high: return String(localized: "El servidor se está quedando sin memoria")
        case .critical: return String(localized: "El servidor casi no tiene memoria")
        }
    }

    /// Explicación con cifras y qué hacer.
    var message: String {
        let used = reading.usedPercent
        if let claude = reading.claudeProcesses, claude > 0 {
            return String(localized: "Usa el \(used) % de la memoria (RAM y swap); procesos de Claude en marcha: \(claude). Si se llena, el sistema empezará a cerrar procesos: detén las sesiones que no estés usando.")
        }
        return String(localized: "Usa el \(used) % de la memoria (RAM y swap). Si se llena, el sistema empezará a cerrar procesos: detén las sesiones que no estés usando.")
    }

    /// Hay que confirmar antes de abrir otra sesión.
    var needsConfirmationToStart: Bool { level == .critical }
}
