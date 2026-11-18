//
//  PersistentAgentHibernation.swift
//  Argos
//
//  Hibernación de agentes persistentes: cuánto tiempo sin actividad se aguanta antes de
//  parar un agente quieto (se reanuda solo al escribirle) y la preferencia del dispositivo.
//
//  Hibernar para el proceso de claude Y TODO SU GRUPO: también lo que lanzó en segundo
//  plano (un servidor de desarrollo, una compilación larga). El vigilante no hiberna si
//  el grupo ha gastado CPU apreciable desde la vuelta anterior, pero un servidor ocioso
//  no gasta CPU: la interfaz lo avisa donde se elige el plazo.
//

import Foundation

struct PersistentAgentHibernation: Equatable, Sendable {
    /// Segundos sin actividad antes de hibernar; 0 = nunca.
    let idleSeconds: Int
    /// Cada cuánto mira el vigilante (segundos).
    let checkSeconds: Int

    static let defaultIdleHours = 4
    static let defaultCheckSeconds = 300
    static let choices = [0, 1, 2, 4, 8, 24]
    static let standard = PersistentAgentHibernation(idleHours: defaultIdleHours)

    /// Segundos de CPU del grupo entre dos vueltas a partir de los cuales el agente se
    /// considera ocupado (algo suyo sigue trabajando aunque el log no cambie).
    static let busyCPUSeconds = 3

    /// Aviso para la interfaz, junto al selector del plazo.
    static let backgroundWorkWarning = "En reposo se detiene el agente y todo lo que lanzó en segundo plano "
        + "(servidores de desarrollo, compilaciones). Si algo suyo sigue usando la CPU, no se pone en reposo."

    init(idleHours: Int) {
        self.init(idleSeconds: max(0, idleHours) * 3600, checkSeconds: Self.defaultCheckSeconds)
    }

    init(idleSeconds: Int, checkSeconds: Int) {
        self.idleSeconds = max(0, idleSeconds)
        self.checkSeconds = max(1, checkSeconds)
    }

    var isEnabled: Bool { idleSeconds > 0 }
    var idleHours: Int { idleSeconds / 3600 }

    static func title(forHours hours: Int) -> String {
        switch hours {
        case 0: return "Nunca"
        case 1: return "1 hora"
        default: return "\(hours) horas"
        }
    }
}

/// Preferencia del dispositivo: horas de inactividad antes de hibernar.
enum AgentHibernationPreferences {
    static let key = "agent.hibernation.idleHours"

    static func idleHours(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: key) != nil else { return PersistentAgentHibernation.defaultIdleHours }
        let stored = defaults.integer(forKey: key)
        return PersistentAgentHibernation.choices.contains(stored) ? stored : PersistentAgentHibernation.defaultIdleHours
    }

    static func setIdleHours(_ hours: Int, defaults: UserDefaults = .standard) {
        defaults.set(hours, forKey: key)
    }

    static func current(defaults: UserDefaults = .standard) -> PersistentAgentHibernation {
        PersistentAgentHibernation(idleHours: idleHours(defaults: defaults))
    }
}
