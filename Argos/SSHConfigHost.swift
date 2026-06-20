//
//  SSHConfigHost.swift
//  Argos
//
//  Lectura y parseo de ~/.ssh/config para mostrar (y poder importar) los hosts ya
//  definidos por el usuario. Lógica pura (parser) separada de la lectura de disco.
//

import Foundation

/// Un bloque `Host` del fichero `~/.ssh/config`.
struct SSHConfigHost: Identifiable, Hashable, Sendable {
    /// Primer patrón de la línea `Host` (el alias por el que conectas: `ssh <alias>`).
    let alias: String
    /// Todos los patrones de la línea `Host` (puede haber varios).
    let patterns: [String]
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?

    var id: String { alias }

    /// `true` si el alias es un comodín (`*`, `?`, `!`): no es un host concreto conectable.
    var isWildcard: Bool {
        patterns.contains { $0.contains("*") || $0.contains("?") || $0.contains("!") }
    }

    /// Host efectivo para conectar: `HostName` si está, si no el propio alias.
    var effectiveHost: String {
        if let hostName, !hostName.isEmpty { return hostName }
        return alias
    }
}

/// Parser del formato de `ssh_config` (subconjunto que nos interesa).
enum SSHConfigParser {
    /// Parsea el texto de un `~/.ssh/config` en bloques `Host`. Las líneas anteriores al
    /// primer `Host` y los bloques `Match` se ignoran (no los modelamos).
    static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost?

        func flush() {
            if let c = current { hosts.append(c) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (keyword, value) = splitKeyValue(line) else { continue }

            switch keyword.lowercased() {
            case "host":
                flush()
                let patterns = value
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                if let first = patterns.first {
                    current = SSHConfigHost(alias: first, patterns: patterns)
                }
            case "match":
                flush() // no modelamos Match
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile": if current?.identityFile == nil { current?.identityFile = value }
            case "proxyjump": current?.proxyJump = value
            default: break
            }
        }
        flush()
        return hosts
    }

    /// Separa "Keyword Value" o "Keyword=Value"; quita comillas envolventes del valor.
    private static func splitKeyValue(_ line: String) -> (keyword: String, value: String)? {
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line, "")
        }
        let keyword = String(line[..<sep])
        var rest = String(line[line.index(after: sep)...])
        rest = String(rest.drop(while: { $0 == " " || $0 == "\t" || $0 == "=" }))
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") {
            rest = String(rest.dropFirst().dropLast())
        }
        return (keyword, rest)
    }
}
