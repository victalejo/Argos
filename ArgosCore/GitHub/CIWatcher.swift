//
//  CIWatcher.swift
//  ArgosCore
//
//  Vigila el CI de commits concretos hasta que termina, para avisar «el CI pasó/falló»
//  aunque el panel «Cambios» ya esté cerrado (Mac e iPhone/iPad en primer plano). Solo
//  se vigila lo que el usuario puso en marcha (un push) o vio en curso: nada de sondear
//  todos los proyectos contra la API de GitHub.
//

import Foundation

/// Un commit cuyo CI se está esperando.
struct CIWatch: Hashable, Sendable {
    let root: String
    /// Nombre para el aviso (el del proyecto).
    let name: String
    /// `nil` tras un push: se fija en la primera lectura (el HEAD recién subido).
    var sha: String?
    let since: Date
}

/// CI terminado de un commit vigilado.
struct CIResult: Hashable, Sendable {
    let watch: CIWatch
    let state: GitHubCheckState
    let failed: [String]
    let url: URL?

    /// Texto del aviso («CI de app: pasó» / «falló: CI, Android»).
    var title: String { "CI de «\(watch.name)»: \(state == .success ? "pasó" : state.label.lowercased())" }
    var body: String {
        let sha = watch.sha.map { String($0.prefix(7)) } ?? ""
        if failed.isEmpty { return "Commit \(sha) · todos los workflows en verde." }
        return "Commit \(sha) · falló: \(failed.joined(separator: ", "))."
    }
}

/// Lógica pura del vigilante (el bucle y la red los pone `SessionsViewModel`).
struct CIWatcher: Sendable {
    /// Cada cuánto se relee un commit vigilado.
    static let pollInterval: TimeInterval = 30
    /// Sin ninguna ejecución tras este tiempo, el repo no usa Actions: se deja de vigilar.
    static let noRunsGiveUp: TimeInterval = 180
    /// Tope de espera (un CI atascado no se vigila para siempre).
    static let maxAge: TimeInterval = 2 * 3600

    private(set) var watches: [String: CIWatch] = [:]
    private(set) var lastPoll: Date?

    var isEmpty: Bool { watches.isEmpty }

    /// Empieza a vigilar `root`. Sin `sha` (tras un push) se fija en la primera lectura; un
    /// commit distinto del vigilado lo sustituye. Repetir la misma petición no reinicia la espera.
    mutating func watch(root: String, name: String, sha: String?, now: Date) {
        if let current = watches[root] {
            if sha == nil || current.sha == sha { return }
            if current.sha == nil {
                watches[root] = CIWatch(root: root, name: current.name, sha: sha, since: current.since)
                return
            }
        }
        watches[root] = CIWatch(root: root, name: name, sha: sha, since: now)
    }

    func isDue(now: Date) -> Bool {
        guard !watches.isEmpty else { return false }
        guard let lastPoll else { return true }
        return now.timeIntervalSince(lastPoll) >= Self.pollInterval
    }

    mutating func markPolled(now: Date) { lastPoll = now }

    /// Aplica la lectura de un commit vigilado. Devuelve el resultado si el CI terminó.
    mutating func apply(_ result: GitHubStatusResult, root: String, now: Date) -> CIResult? {
        guard var watch = watches[root] else { return nil }
        let snapshot: GitHubSnapshot
        switch result {
        case .loaded(let loaded): snapshot = loaded
        case .failed: return nil  // fallo pasajero (red): se reintenta en la próxima vuelta
        case .ghMissing, .notAuthenticated, .notGitHub:
            watches[root] = nil  // no hay CI que vigilar
            return nil
        }
        if watch.sha == nil { watch.sha = snapshot.headSha; watches[root] = watch }
        // HEAD cambió (otro commit encima): las ejecuciones ya serían de otro commit. Se deja;
        // si se sube el nuevo, el push o el panel lo vuelven a vigilar.
        guard watch.sha == snapshot.headSha else {
            watches[root] = nil
            return nil
        }
        let age = now.timeIntervalSince(watch.since)
        guard let state = snapshot.ciState else {
            if age > Self.noRunsGiveUp { watches[root] = nil }
            return nil
        }
        if snapshot.isCIRunning {
            if age > Self.maxAge { watches[root] = nil }
            return nil
        }
        watches[root] = nil
        let failed = snapshot.runs.filter { $0.state == .failure }
        return CIResult(watch: watch, state: state, failed: failed.map(\.workflow),
                        url: (failed.first ?? snapshot.runs.first)?.url)
    }
}
