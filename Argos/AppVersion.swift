//
//  AppVersion.swift
//  Argos
//
//  Versión semántica comparable (lógica pura, testeable). Sirve para comparar la
//  versión instalada con la del último GitHub Release y decidir si hay actualización.
//

import Foundation

/// Versión tipo `MAJOR.MINOR.PATCH` comparable numéricamente.
///
/// Tolera un prefijo `v`/`V` (`v1.0.2`), componentes faltantes (`1.0` == `1.0.0`) y
/// descarta metadatos de pre-release/build (`1.0.2-beta`, `1.0.2+build` → `1.0.2`).
struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let components: [Int]
    let raw: String

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var core = trimmed
        if let first = core.first, first == "v" || first == "V" {
            core.removeFirst()
        }
        // Descarta pre-release (`-`) y build metadata (`+`).
        if let dash = core.firstIndex(of: "-") { core = String(core[..<dash]) }
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }

        self.components = parts.map { $0! }
        self.raw = trimmed
    }

    /// Componente en `index`, o 0 si la versión tiene menos componentes (padding).
    private func component(at index: Int) -> Int {
        index < components.count ? components[index] : 0
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = lhs.component(at: i)
            let r = rhs.component(at: i)
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count where lhs.component(at: i) != rhs.component(at: i) {
            return false
        }
        return true
    }

    var description: String { raw }
}
