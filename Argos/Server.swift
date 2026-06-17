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

/// Un servidor SSH configurable y persistible.
struct Server: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Nombre visible en la UI (p. ej. "dev", "producción").
    var name: String
    var host: String
    var port: Int
    var username: String
    /// Ruta legible a la clave privada Ed25519 (admite `~`).
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
        privateKeyPath: String,
        privateKeyBookmark: Data? = nil,
        requiresPassphrase: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyPath = privateKeyPath
        self.privateKeyBookmark = privateKeyBookmark
        self.requiresPassphrase = requiresPassphrase
    }

    /// Endpoint "host:port" — identidad para la verificación TOFU de host key.
    var endpoint: String { "\(host):\(port)" }
}
