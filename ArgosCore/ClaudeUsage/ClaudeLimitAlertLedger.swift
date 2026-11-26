//
//  ClaudeLimitAlertLedger.swift
//  ArgosCore
//
//  Avisos de límites de Claude ya dados (por servidor, ventana, reinicio y nivel). Un view
//  model nuevo (arranque de la app, reconexión) empieza sin lectura anterior y volvería a
//  avisar; con esto, cada aviso sale una sola vez. Se guarda en `UserDefaults` (solo claves,
//  sin datos del servidor) y se recorta para no crecer sin fin: las claves llevan la hora de
//  reinicio, así que las viejas ya no se repiten.
//

import Foundation

enum ClaudeLimitAlertLedger {

    private static let defaultsKey = "claudeLimits.notifiedAlerts"
    /// Claves que se conservan (las más recientes).
    static let capacity = 64

    /// `true` la primera vez que se pide `key`; después, `false`.
    @discardableResult
    static func claim(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        var keys = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !keys.contains(key) else { return false }
        keys.append(key)
        defaults.set(Array(keys.suffix(capacity)), forKey: defaultsKey)
        return true
    }
}
