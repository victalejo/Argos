//
//  SessionsViewModel+CI.swift
//  ArgosCore
//
//  Avisos «el CI pasó/falló» de los commits que el usuario subió desde Argos o vio con
//  el CI en curso. El bucle de sondeo de cada plataforma llama a `pollCIWatches` y
//  notifica lo que devuelva; la lógica de cuándo dejar de vigilar está en `CIWatcher`.
//

import Foundation

extension SessionsViewModel {

    /// Empieza a vigilar el CI de `root` (`sha` nil tras un push: el HEAD subido).
    func watchCI(root: String, sha: String? = nil, now: Date = Date()) {
        ciWatcher.watch(root: root, name: projectName(forRoot: root), sha: sha, now: now)
    }

    /// Relee los commits vigilados si toca; devuelve los CI que terminaron.
    func pollCIWatches(now: Date = Date()) async -> [CIResult] {
        guard ciWatcher.isDue(now: now) else { return [] }
        ciWatcher.markPolled(now: now)
        var finished: [CIResult] = []
        for root in ciWatcher.watches.keys.sorted() {
            let result: GitHubStatusResult
            do {
                result = try await service.gitHubStatus(root: root)
            } catch {
                Log.ssh.notice("CI vigilado de \(root, privacy: .public): \(error.userMessage, privacy: .public)")
                continue
            }
            if let done = ciWatcher.apply(result, root: root, now: now) { finished.append(done) }
        }
        return finished
    }

    /// Nombre del proyecto cuya carpeta es `root` (o el último componente de la ruta).
    func projectName(forRoot root: String) -> String {
        projects.first { $0.path == root }?.name ?? (root as NSString).lastPathComponent
    }
}
