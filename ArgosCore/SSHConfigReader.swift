//
//  SSHConfigReader.swift
//  Argos
//
//  Lee `~/.ssh/config` del home REAL del usuario (bajo App Sandbox `NSHomeDirectory()`
//  apunta al container). El permiso de lectura lo da `SSHDirectoryAccess`: la
//  excepción de sandbox en el canal GitHub o la carpeta concedida en el de App Store.
//

import Foundation

enum SSHConfigReader {
    /// Ruta absoluta a `~/.ssh/config` en el home real del usuario.
    static var configPath: String {
        SSHDirectoryAccess.directoryPath() + "/config"
    }

    enum Result: Equatable {
        case hosts([SSHConfigHost])
        case noFile
        /// Falta que el usuario conceda la carpeta ~/.ssh (canal App Store).
        case needsAccess
        case failed(String)
    }

    static func read(defaults: UserDefaults = .standard) -> Result {
        if SSHDirectoryAccess.currentStatus(defaults: defaults) == .needsGrant {
            return .needsAccess
        }
        let path = configPath
        return SSHDirectoryAccess.withAccess(defaults: defaults) {
            guard FileManager.default.fileExists(atPath: path) else { return .noFile }
            do {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                return .hosts(SSHConfigParser.parse(text))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }
}
