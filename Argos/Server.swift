//
//  Server.swift
//  Argos
//
//  Perfil de un servidor SSH gestionado por la app. Sustituye a la antigua
//  `SSHService.Configuration.dev` hardcodeada: ahora la app es multi-servidor y
//  los perfiles se persisten (ver `ServerStore`).
//
//  La passphrase NO se guarda aquí: vive en Keychain (ver `KeychainStore`),
//  referenciada por el `id` del servidor. La ruta de la clave se guarda como
//  texto (informativo / modo sin sandbox) y, bajo App Sandbox, como
//  security-scoped bookmark que el usuario concede al elegir el archivo.
//

import Foundation

/// Método de autenticación de un servidor SSH.
enum AuthMethod: String, Codable, Sendable, CaseIterable {
    /// Clave privada Ed25519 (con passphrase opcional en Keychain).
    case key
    /// Usuario + contraseña (la contraseña vive en Keychain).
    case password
}

/// Un servidor SSH configurable y persistible.
struct Server: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Nombre visible en la UI (p. ej. "dev", "producción").
    var name: String
    var host: String
    var port: Int
    var username: String
    /// Método de autenticación (clave o contraseña).
    var authMethod: AuthMethod
    /// Ruta legible a la clave privada Ed25519 (admite `~`). Solo para `authMethod == .key`.
    var privateKeyPath: String
    /// Bookmark con security-scope para leer la clave bajo App Sandbox.
    /// `nil` mientras la app corre sin sandbox o hasta que el usuario la elige.
    var privateKeyBookmark: Data?
    /// Si la clave requiere passphrase (la passphrase real está en Keychain).
    var requiresPassphrase: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .key,
        privateKeyPath: String = "",
        privateKeyBookmark: Data? = nil,
        requiresPassphrase: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.privateKeyBookmark = privateKeyBookmark
        self.requiresPassphrase = requiresPassphrase
    }

    // Codable retrocompatible: los `servers.json` previos no tienen `authMethod`;
    // al faltar se asume `.key` (comportamiento histórico).
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod
        case privateKeyPath, privateKeyBookmark, requiresPassphrase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .key
        privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        privateKeyBookmark = try c.decodeIfPresent(Data.self, forKey: .privateKeyBookmark)
        requiresPassphrase = try c.decodeIfPresent(Bool.self, forKey: .requiresPassphrase) ?? false
    }

    /// Endpoint "host:port" — identidad para la verificación TOFU de host key.
    var endpoint: String { "\(host):\(port)" }
}
