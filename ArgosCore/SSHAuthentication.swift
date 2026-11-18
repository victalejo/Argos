//
//  SSHAuthentication.swift
//  Argos
//
//  Método de autenticación de `SSHService`: clave Ed25519 (con passphrase opcional, leída
//  por security-scoped bookmark o por ruta) o usuario + contraseña.
//

import Foundation
@preconcurrency import Citadel
import Crypto      // Curve25519.Signing.PrivateKey

extension SSHService {

    /// Construye el método de autenticación según el `authMethod` configurado:
    /// clave Ed25519 (con passphrase opcional) o usuario+contraseña.
    func makeAuthenticationMethod() throws -> SSHAuthenticationMethod {
        switch configuration.authMethod {
        case .key:
            let privateKey = try loadPrivateKey()
            return .ed25519(username: configuration.username, privateKey: privateKey)
        case .password:
            // Sin contraseña no se toca la red: probar con una vacía solo suma intentos
            // fallidos en el servidor (fail2ban) cada vez que se sondea en segundo plano.
            guard let password = configuration.password, !password.isEmpty else {
                throw SSHServiceError.credentialUnavailable
            }
            return .passwordBased(username: configuration.username, password: password)
        }
    }

    /// Lee y parsea la clave Ed25519 OpenSSH del disco.
    private func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        let keyText = try readKeyText()

        // Passphrase opcional -> Data UTF-8 (nil si la clave no está cifrada).
        let decryptionKey = configuration.passphrase.map { Data($0.utf8) }

        do {
            return try Curve25519.Signing.PrivateKey(
                sshEd25519: keyText,
                decryptionKey: decryptionKey
            )
        } catch {
            throw SSHServiceError.keyParseFailed(underlying: error)
        }
    }

    /// Lee el texto de la clave privada. Bajo App Sandbox resuelve el
    /// security-scoped bookmark que el usuario concedió al elegir el archivo; si
    /// no hay bookmark (modo sin sandbox), lee por ruta directa (admite `~`).
    private func readKeyText() throws -> String {
        if let bookmark = configuration.privateKeyBookmark {
            do {
                var isStale = false
                // macOS exige `.withSecurityScope` para bookmarks del sandbox; en iOS
                // los bookmarks de archivos elegidos ya llevan el scope implícito.
                #if os(macOS)
                let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
                #else
                let resolveOptions: URL.BookmarkResolutionOptions = []
                #endif
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: resolveOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw SSHServiceError.keyUnreadable(
                    path: configuration.privateKeyPath, underlying: error
                )
            }
        }

        let path = SSHDirectoryAccess.expandTilde(configuration.privateKeyPath)
        do {
            // Claves en ~/.ssh: con el permiso de carpeta concedido (canal App Store) o
            // por la excepción de sandbox (canal GitHub).
            return try SSHDirectoryAccess.withAccess {
                try String(contentsOfFile: path, encoding: .utf8)
            }
        } catch {
            throw SSHServiceError.keyUnreadable(path: path, underlying: error)
        }
    }
}
