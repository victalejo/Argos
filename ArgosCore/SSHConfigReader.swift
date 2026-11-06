//
//  SSHConfigReader.swift
//  Argos
//
//  Lee `~/.ssh/config` del home REAL del usuario (bajo App Sandbox `NSHomeDirectory()`
//  apunta al container; `getpwuid` da el home POSIX real). El acceso de lectura a
//  `~/.ssh` lo concede el entitlement `temporary-exception.files.home-relative-path`.
//

import Foundation

enum SSHConfigReader {
    /// Ruta absoluta a `~/.ssh/config` en el home real del usuario.
    static var configPath: String {
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        }
        return home + "/.ssh/config"
    }

    enum Result: Equatable {
        case hosts([SSHConfigHost])
        case noFile
        case failed(String)
    }

    static func read() -> Result {
        let path = configPath
        guard FileManager.default.fileExists(atPath: path) else { return .noFile }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            return .hosts(SSHConfigParser.parse(text))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
