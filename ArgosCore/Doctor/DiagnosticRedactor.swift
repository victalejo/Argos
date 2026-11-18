//
//  DiagnosticRedactor.swift
//  ArgosCore
//
//  Redacción (lógica pura) del informe «Copiar diagnóstico».
//   · SIEMPRE (aunque el usuario pida incluir sus datos): se quitan secretos: rutas de claves
//     privadas, tokens de Anthropic/GitHub, contraseñas y cabeceras `Bearer`.
//   · Por defecto además se sustituyen los datos personales por marcadores estables dentro de
//     un mismo informe: servidores (nombre, host, IP) → «servidor-N», usuarios → «usuario-N»
//     (en `usuario@host`, `/home/<usuario>` y `/Users/<usuario>`), IPs v4/v6 → «servidor-N».
//  Es un `struct` con estado (los marcadores se asignan por orden de aparición): usa la misma
//  instancia para todas las secciones de un informe.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

extension DiagnosticRedactor.KnownServer {
    /// Un servidor configurado en la app (nombre, host y usuario se ocultan por defecto).
    init(_ server: Server) {
        self.init(name: server.name, host: server.host, username: server.username)
    }
}

struct DiagnosticRedactor {

    /// Un servidor configurado en la app: sus nombres se conocen de antemano.
    struct KnownServer: Equatable, Sendable {
        let name: String
        let host: String
        let username: String

        init(name: String, host: String, username: String) {
            self.name = name
            self.host = host
            self.username = username
        }
    }

    let includesPersonalData: Bool
    private var serverAliases: [String: String] = [:]
    private var userAliases: [String: String] = [:]
    private var serverCount = 0
    /// Nombres y hosts conocidos, del más largo al más corto (que «example.com» no pise a «dev.example.com»).
    private var knownTerms: [String] = []

    init(knownServers: [KnownServer] = [], includesPersonalData: Bool = false) {
        self.includesPersonalData = includesPersonalData
        var terms: [String] = []
        for server in knownServers {
            // Un marcador por servidor: nombre, host y cualquier IP comparten `servidor-N`.
            let alias = serverAlias(for: server.host.isEmpty ? server.name : server.host)
            if !server.name.isEmpty { serverAliases[server.name.lowercased()] = alias }
            terms += [server.host, server.name].filter { !$0.isEmpty }
            let user = server.username.trimmingCharacters(in: .whitespaces)
            if !user.isEmpty { _ = userAlias(for: user) }
        }
        knownTerms = Array(Set(terms)).sorted { $0.count > $1.count }
    }

    // MARK: - API

    /// Texto sin secretos y (salvo que se pida lo contrario) sin datos personales.
    mutating func redact(_ text: String) -> String {
        var result = Self.scrubSecrets(text)
        guard !includesPersonalData else { return result }
        result = redactKnownTerms(in: result)
        result = redactUserHost(in: result)
        result = redactHomePaths(in: result)
        result = redactIPv6(in: result)
        result = redactIPv4(in: result)
        return result
    }

    /// Marcador para un nombre de servidor concreto (el del encabezado del informe).
    mutating func serverLabel(_ name: String) -> String {
        includesPersonalData ? Self.scrubSecrets(name) : redact(name)
    }

    // MARK: - Secretos (siempre)

    static let keyPathMarker = DiagnosticSecretScrubber.keyPathMarker
    static let secretMarker = DiagnosticSecretScrubber.marker

    /// Quita secretos (siempre, antes que nada y sin depender de ninguna opción).
    static func scrubSecrets(_ text: String) -> String {
        DiagnosticSecretScrubber.scrub(text)
    }

    // MARK: - Datos personales

    private mutating func serverAlias(for term: String) -> String {
        let key = term.lowercased()
        if let alias = serverAliases[key] { return alias }
        serverCount += 1
        let alias = "servidor-\(serverCount)"
        serverAliases[key] = alias
        return alias
    }

    private mutating func userAlias(for user: String) -> String {
        if let alias = userAliases[user] { return alias }
        let alias = "usuario-\(userAliases.count + 1)"
        userAliases[user] = alias
        return alias
    }

    private mutating func redactKnownTerms(in text: String) -> String {
        var result = text
        for term in knownTerms {
            let pattern = #"(?<![A-Za-z0-9.\-])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![A-Za-z0-9\-]|\.[A-Za-z0-9])"#
            let alias = serverAlias(for: term)
            result = Self.replace(pattern, in: result, options: [.caseInsensitive], with: alias)
        }
        return result
    }

    /// `usuario@host` (también correos): ambos lados pasan a marcadores.
    private mutating func redactUserHost(in text: String) -> String {
        Self.replace(#"(?<![A-Za-z0-9._\-])([A-Za-z0-9._\-]+)@([A-Za-z0-9.\-]+|\[[0-9A-Fa-f:.]+\])"#, in: text) { match in
            guard let at = match.firstIndex(of: "@") else { return match }
            let user = String(match[..<at])
            let host = String(match[match.index(after: at)...])
            if user.hasPrefix("usuario-"), host.hasPrefix("servidor-") { return match }   // ya redactado
            return "\(userAlias(for: user))@\(hostAlias(host))"
        }
    }

    private mutating func hostAlias(_ host: String) -> String {
        host.hasPrefix("servidor-") ? host : serverAlias(for: host)
    }

    private mutating func redactHomePaths(in text: String) -> String {
        return Self.replace(#"/(?:home|Users)/([^/\s"'<>:]+)"#, in: text) { match in
            let parts = match.split(separator: "/")
            guard parts.count == 2 else { return match }
            let user = String(parts[1])
            if user.hasPrefix("usuario-") || user == "Shared" { return match }
            return "/\(parts[0])/\(userAlias(for: user))"
        }
    }

    private mutating func redactIPv4(in text: String) -> String {
        return Self.replace(#"(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9]|\.\d)"#, in: text) { match in
            let octets = match.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return match }
            return serverAlias(for: match)
        }
    }

    private mutating func redactIPv6(in text: String) -> String {
        return Self.replace(#"(?<![0-9A-Za-z:.])[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*(?![0-9A-Za-z:])"#, in: text) { match in
            // Sin `%zona` y validado por el sistema: «12:30:45» no es una IPv6.
            guard Self.isIPv6(match) else { return match }
            return serverAlias(for: match)
        }
    }

    static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    // MARK: - Utilidades de expresiones regulares

    private static func replace(
        _ pattern: String, in text: String, options: NSRegularExpression.Options = [], with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Sustituye cada coincidencia por lo que devuelva `transform`. Los marcadores se asignan
    /// por orden de aparición (de izquierda a derecha); el texto se reescribe de atrás adelante.
    private static func replace(_ pattern: String, in text: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let replacements: [(Range<String.Index>, String)] = matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return (range, transform(String(text[range])))
        }
        var result = text
        for (range, value) in replacements.reversed() { result.replaceSubrange(range, with: value) }
        return result
    }
}
