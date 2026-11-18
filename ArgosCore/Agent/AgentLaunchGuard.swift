//
//  AgentLaunchGuard.swift
//  Argos
//
//  Guardia antes de arrancar otro `claude` en un servidor (lógica pura, compartida por
//  el panel del Mac y los agentes del iPhone/iPad). Cada `claude` ocupa ~0,5 GB y el
//  servidor del usuario ya se quedó una vez sin memoria por acumularlos: con poca
//  memoria libre o demasiados agentes vivos se AVISA y se deja seguir bajo confirmación.
//

import Foundation

enum AgentLaunchGuard {

    /// Por debajo de esto no se arranca un agente sin confirmación (KB).
    static let minimumFreeMemoryKB = 900_000
    /// Agentes vivos a partir de los cuales se pide confirmación (en todo el servidor).
    static let maxLiveAgents = 6

    enum Assessment: Equatable, Sendable {
        case ok
        /// Hay que confirmar: `title` para el aviso y `message` con el porqué.
        case warning(title: String, message: String)
    }

    /// `freeMemoryKB` `nil` = no se sabe (servidor no Linux): no se avisa por memoria.
    static func assess(freeMemoryKB: Int?, liveAgents: Int) -> Assessment {
        if let free = freeMemoryKB, free < minimumFreeMemoryKB {
            return .warning(
                title: "Poca memoria libre en el servidor",
                message: "Quedan \(ResourceFormat.kilobytes(free)) libres y cada agente de Claude ocupa unos 0,5 GB. "
                    + "Detén o hiberna agentes que no uses para liberar memoria."
            )
        }
        if liveAgents >= maxLiveAgents {
            return .warning(
                title: "Ya hay \(liveAgents) agentes en marcha",
                message: "Cada agente de Claude ocupa unos 0,5 GB en el servidor. "
                    + "Detén o hiberna alguno antes de abrir otro, o continúa si sabes que hay memoria."
            )
        }
        return .ok
    }
}
