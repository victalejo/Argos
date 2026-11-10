//
//  ListeningPort.swift
//  ArgosCore
//
//  Puertos TCP que escuchan en el servidor (lógica pura): lo que se puede reenviar al
//  dispositivo. Se leen con `ss -tln` (o `netstat -tln` si no hay `ss`).
//

import Foundation

/// Un puerto TCP en escucha en el servidor.
struct ListeningPort: Identifiable, Hashable, Sendable {
    let port: Int
    /// Host al que pide conectar el túnel en el servidor: `localhost` si escucha en
    /// loopback o en todas las interfaces; si no, la dirección concreta.
    let targetHost: String
    /// Proceso dueño (solo si es del mismo usuario: `ss -p` no ve los ajenos).
    let processName: String?

    var id: Int { port }

    /// Puertos de sistema (DNS local, CUPS, sshd…) que no interesa reenviar. Se dejan
    /// 80/443/8080 por si un servidor web de desarrollo corre ahí.
    var isLikelyDevServer: Bool {
        if processName == "sshd" || port == 22 { return false }
        return port >= 1024 || [80, 443].contains(port)
    }
}

enum ListeningPortParser {

    /// Comando remoto (solo lectura). `-p` añade el proceso; si `ss` no admite `-H`
    /// o `-p`, se reintenta sin ellos; la cabecera la descarta el parser.
    static let command = ShellQuoting.posixShell("""
    if command -v ss >/dev/null 2>&1; then
      ss -Htlnp 2>/dev/null || ss -tln
    else
      netstat -tln 2>/dev/null
    fi
    """)

    static func parse(_ output: String) -> [ListeningPort] {
        var byPort: [Int: ListeningPort] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let local = localAddressField(fields),
                  let (address, port) = splitHostPort(local)
            else { continue }
            let entry = ListeningPort(
                port: port,
                targetHost: targetHost(for: address),
                processName: processName(in: String(line))
            )
            // IPv4 + IPv6 del mismo puerto: uno. Se prefiere el que dice el proceso y
            // el que llega por `localhost`.
            if let existing = byPort[port] {
                let better = (existing.processName == nil && entry.processName != nil)
                    || (existing.targetHost != "localhost" && entry.targetHost == "localhost")
                if better {
                    byPort[port] = ListeningPort(
                        port: port,
                        targetHost: entry.targetHost == "localhost" ? "localhost" : existing.targetHost,
                        processName: entry.processName ?? existing.processName
                    )
                }
            } else {
                byPort[port] = entry
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// Columna de la dirección local: la 4ª en `ss` (`LISTEN 0 511 *:3000 *:*`) y en
    /// `netstat` (`tcp 0 0 0.0.0.0:3000 0.0.0.0:* LISTEN`). Las cabeceras no coinciden.
    private static func localAddressField(_ fields: [String]) -> String? {
        guard fields.count >= 4 else { return nil }
        let first = fields[0].lowercased()
        if first == "listen" { return fields[3] }
        if first.hasPrefix("tcp"), fields.last?.uppercased() == "LISTEN" { return fields[3] }
        return nil
    }

    /// `127.0.0.1:3000`, `*:3000`, `[::]:3000`, `:::3000`, `127.0.0.53%lo:53`.
    static func splitHostPort(_ value: String) -> (String, Int)? {
        guard let colon = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: colon)...]),
              (1...65535).contains(port)
        else { return nil }
        var host = String(value[..<colon])
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return (host, port)
    }

    private static let wildcardOrLoopback: Set<String> = ["", "*", "0.0.0.0", "::", ":", "::1", "localhost"]

    static func targetHost(for address: String) -> String {
        if wildcardOrLoopback.contains(address) || address.hasPrefix("127.") { return "localhost" }
        return address
    }

    /// Primer nombre de `users:(("node",pid=123,fd=20))`.
    private static func processName(in line: String) -> String? {
        guard let start = line.range(of: "((\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let name = String(rest[..<end])
        return name.isEmpty ? nil : name
    }
}
