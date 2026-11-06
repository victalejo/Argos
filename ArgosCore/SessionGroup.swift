//
//  SessionGroup.swift
//  Argos
//
//  Fase 3: agrupamiento de sesiones por convención de nombres, SIN estado extra.
//
//  El prefijo anterior al primer '/' define el grupo:
//      "magic-agents/backend" y "magic-agents/frontend" -> grupo "magic-agents"
//  Las sesiones sin '/' caen en el grupo "General".
//
//  El nombre COMPLETO sigue siendo la identidad/target real de la sesión (el id de
//  `TmuxSession`); el nombre corto (lo de después del primer '/') es solo para mostrar.
//

import Foundation

/// Un grupo de sesiones que comparten prefijo. Tipo puro, listo para una `Section`.
struct SessionGroup: Identifiable {
    /// Nombre del grupo ("magic-agents", "General", …). Único en la lista.
    let name: String
    /// Sesiones del grupo, ya ordenadas por su nombre corto.
    let sessions: [TmuxSession]

    var id: String { name }
}

/// Lógica pura de agrupamiento por prefijo. Sin dependencias de red ni UI.
enum SessionGrouping {

    /// Separador de grupo dentro del nombre de la sesión.
    static let separator: Character = "/"

    /// Grupo al que van las sesiones sin separador.
    static let ungroupedName = "General"

    /// Descompone un nombre completo en `(grupo, nombreCorto)`.
    ///
    /// - "magic-agents/backend" -> ("magic-agents", "backend")
    /// - "main"                 -> ("General", "main")
    /// - "/foo" (prefijo vacío) -> ("General", "/foo")   (no es un grupo real)
    /// - "foo/" (sufijo vacío)  -> ("foo", "foo/")        (sin nombre corto utilizable)
    static func split(_ fullName: String) -> (group: String, short: String) {
        guard let index = fullName.firstIndex(of: separator) else {
            return (ungroupedName, fullName)
        }
        let prefix = String(fullName[..<index])
        let suffix = String(fullName[fullName.index(after: index)...])
        guard !prefix.isEmpty else { return (ungroupedName, fullName) }
        // Si no queda nada tras el '/', mostramos el nombre completo para no dejar
        // la fila sin etiqueta.
        return (prefix, suffix.isEmpty ? fullName : suffix)
    }

    /// Nombre del grupo de una sesión.
    static func groupName(for fullName: String) -> String { split(fullName).group }

    /// Nombre corto (para mostrar) de una sesión.
    static func shortName(for fullName: String) -> String { split(fullName).short }

    /// Agrupa y ordena las sesiones.
    ///
    /// - Grupos: alfabéticamente (sin distinguir mayúsculas), con "General" SIEMPRE al final.
    /// - Dentro de cada grupo: por nombre corto, alfabéticamente.
    static func groups(from sessions: [TmuxSession]) -> [SessionGroup] {
        var buckets: [String: [TmuxSession]] = [:]
        var order: [String] = []
        for session in sessions {
            let group = split(session.name).group
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(session)
        }

        let sortedGroupNames = order.sorted { lhs, rhs in
            if lhs == ungroupedName { return false }
            if rhs == ungroupedName { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return sortedGroupNames.map { name in
            let sorted = (buckets[name] ?? []).sorted {
                shortName(for: $0.name)
                    .localizedCaseInsensitiveCompare(shortName(for: $1.name)) == .orderedAscending
            }
            return SessionGroup(name: name, sessions: sorted)
        }
    }
}
