//
//  TerminalKeepAlivePool.swift
//  ArgosCore
//
//  Qué terminales siguen vivos sin estar en pantalla. Al cambiar a Archivos, Cambios o
//  Agentes (o al girar/redimensionar, que desmonta la vista un instante) el terminal se
//  «aparca» en vez de cerrarse: volver es instantáneo, sin handshake SSH ni repintado.
//  Un aparcado se cierra al pasar `grace` o si hay más terminales vivos que `maxLive`
//  (primero el aparcado hace más tiempo). Lógica pura e inmutable.
//

import Foundation

struct TerminalKeepAlivePool<Key: Hashable & Sendable>: Sendable {
    /// Cuánto sigue vivo un terminal aparcado.
    let grace: Duration
    /// Tope de terminales vivos (en pantalla + aparcados).
    let maxLive: Int

    /// Terminales en pantalla.
    private(set) var visible: Set<Key> = []
    /// Aparcados con el instante en que dejaron de verse.
    private(set) var parked: [Key: ContinuousClock.Instant] = [:]

    init(grace: Duration = .seconds(180), maxLive: Int = 4) {
        self.grace = grace
        self.maxLive = max(1, maxLive)
    }

    var live: Set<Key> { visible.union(parked.keys) }

    /// El terminal vuelve a la pantalla (o aparece por primera vez).
    func showing(_ key: Key) -> TerminalKeepAlivePool {
        var copy = self
        copy.parked.removeValue(forKey: key)
        copy.visible.insert(key)
        return copy
    }

    /// El terminal sale de la pantalla pero sigue vivo.
    func parking(_ key: Key, at now: ContinuousClock.Instant) -> TerminalKeepAlivePool {
        guard live.contains(key) else { return self }
        var copy = self
        copy.visible.remove(key)
        copy.parked[key] = now
        return copy
    }

    /// El terminal se cerró de verdad (matar o renombrar la sesión, borrar el servidor).
    func removing(_ key: Key) -> TerminalKeepAlivePool {
        var copy = self
        copy.visible.remove(key)
        copy.parked.removeValue(forKey: key)
        return copy
    }

    /// Aparcados que hay que cerrar ya: caducados y, si aún sobran, los más antiguos.
    /// Los terminales en pantalla nunca se cierran.
    func evictions(at now: ContinuousClock.Instant) -> [Key] {
        let expired = parked.filter { now - $0.value >= grace }.map(\.key)
        let remaining = parked.filter { now - $0.value < grace }
            .sorted { $0.value < $1.value }
            .map(\.key)
        let overflow = max(0, visible.count + remaining.count - maxLive)
        return expired + remaining.prefix(overflow)
    }

    /// Instante en que caduca el próximo aparcado (para programar la limpieza).
    var nextExpiry: ContinuousClock.Instant? {
        parked.values.min().map { $0 + grace }
    }

    /// Al pasar a segundo plano: los aparcados se cierran (no se reabren al volver).
    func droppingParked() -> (pool: TerminalKeepAlivePool, dropped: [Key]) {
        var copy = self
        let dropped = Array(parked.keys)
        copy.parked = [:]
        return (copy, dropped)
    }
}
